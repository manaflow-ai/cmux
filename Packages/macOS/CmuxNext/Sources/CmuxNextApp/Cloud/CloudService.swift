import AppKit
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Observation
import os

/// Cloud orchestration: sign-in state, the machine list from `/api/vm`, and
/// one `CloudMachineSession` per live machine in `MachineRegistry`. The
/// list is fetched when the session restores or signs in, after every
/// machine mutation, and when the app becomes active (at most every 30 s);
/// there is no polling timer.
@Observable
final class CloudService {
    let configuration: CloudConfiguration
    let auth: CloudAuth
    @ObservationIgnored let api: CloudAPIClient
    @ObservationIgnored let paths: CloudPaths
    @ObservationIgnored private(set) var hub: CloudTunnelHub?
    @ObservationIgnored private let machines: MachineRegistry
    @ObservationIgnored private let binary: URL?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    /// The last list or connection failure, for diagnostics and refusals.
    private(set) var lastError: String?
    private(set) var hasLoadedMachines = false
    /// Machine creations in flight (sidebar can show a placeholder).
    private(set) var creating = 0

    init(machines: MachineRegistry, isDebugBuild: Bool) {
        self.machines = machines
        configuration = CloudConfiguration.current(isDebugBuild: isDebugBuild)
        auth = CloudAuth(configuration: configuration)
        paths = CloudPaths.standard(bundleID: configuration.bundleID)
        let auth = auth
        api = CloudAPIClient(
            configuration: configuration,
            tokens: { try await auth.tokens() },
            teamID: { await auth.teamID }
        )
        binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        if let binary {
            hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: Self.deviceName)
        }
    }

    /// `cmux-<host>`, as the old app named its link device. Reads the kernel
    /// hostname (`gethostname`): `ProcessInfo.hostName` resolves through DNS
    /// and blocked the main thread for 35 s on launch.
    static var deviceName: String {
        let name = MacName.kernelHostName()
        let host = name.isEmpty ? "mac" : name
        let cleaned = host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "cmux-" + String(String(cleaned).prefix(40))
    }

    var isSignedIn: Bool { auth.isSignedIn }

    /// Why Cloud cannot run in this build, or nil.
    var unavailableReason: String? {
        if case .localOnly = configuration.backend { return CloudStrings.localBackend }
        if binary == nil { return CloudStrings.noClient }
        return nil
    }

    func start() {
        auth.start()
        observers.append(Task { [weak self] in
            guard let self else { return }
            await auth.awaitRestored()
            for await signedIn in Observations({ self.auth.isSignedIn }) {
                if signedIn {
                    // Sign-out revoked the WireGuard peer and parked the hub.
                    await self.hub?.resume()
                    await self.refresh()
                } else {
                    self.dropAllMachines()
                }
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self, let last = self.lastRefresh, last.duration(to: .now) > .seconds(30) else { continue }
                await self.refresh()
            }
        })
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        for session in machines.cloud { session.disconnect() }
        // task-owner: teardown hop at quit; hub.stop() is idempotent
        if let hub { Task { await hub.stop() } }
    }

    // MARK: Machine list

    /// Fetches `/api/vm` and reconciles sessions: new live machines connect,
    /// gone machines disconnect, records update in place.
    func refresh() async {
        guard auth.isSignedIn, unavailableReason == nil else { return }
        lastRefresh = .now
        do {
            let list = try await api.listMachines()
            lastError = nil
            reconcile(list)
            hasLoadedMachines = true
        } catch {
            lastError = String(describing: error)
            logger.error("machine list failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func reconcile(_ list: [CloudMachine]) {
        let visible = list.filter { $0.status != .destroyed }
        for machine in visible {
            if let session = machines.session(machine.id) {
                let wasLive = session.machine.status.isLive
                session.machine = machine
                if wasLive, !machine.status.isLive {
                    session.suspend()
                } else if !wasLive, machine.status.isLive {
                    session.connect()
                }
            } else {
                addSession(machine)
            }
        }
        let ids = Set(visible.map(\.id))
        for session in machines.cloud where !ids.contains(session.machineID) {
            machines.remove(session.machineID)?.disconnect()
        }
    }

    @discardableResult
    private func addSession(_ machine: CloudMachine) -> CloudMachineSession? {
        guard let hub, let binary else { return nil }
        let link = CloudMachineLink(machineID: machine.id, api: api, hub: hub, paths: paths, binary: binary, deviceName: Self.deviceName)
        let session = CloudMachineSession(machine: machine, link: link)
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        session.connect()
        return session
    }

    private func dropAllMachines() {
        for session in machines.cloud { machines.remove(session.machineID)?.disconnect() }
        hasLoadedMachines = false
    }

    // MARK: Mutations

    /// Creates a machine and connects to it. Returns its session.
    func createMachine(name: String?) async throws -> CloudMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        guard auth.isSignedIn else { throw ActionFailure(message: CloudStrings.signInFirst) }
        creating += 1
        defer { creating -= 1 }
        let machine = try await api.createMachine(displayName: name)
        logger.info("created machine \(machine.id, privacy: .public)")
        if let existing = machines.session(machine.id) { return existing }
        guard let session = addSession(machine) else { throw ActionFailure(message: CloudStrings.noClient) }
        return session
    }

    func deleteMachine(_ machineID: String) async throws {
        try await api.deleteMachine(machineID)
        machines.remove(machineID)?.disconnect()
        logger.info("deleted machine \(machineID, privacy: .public)")
    }

    func pauseMachine(_ machineID: String) async throws {
        try await api.pauseMachine(machineID)
        await refresh()
        logger.info("paused machine \(machineID, privacy: .public)")
    }

    func resumeMachine(_ machineID: String) async throws {
        try await api.resumeMachine(machineID)
        await refresh()
        logger.info("resumed machine \(machineID, privacy: .public)")
    }

    func renameMachine(_ machineID: String, to name: String) async throws {
        try await api.renameMachine(machineID, to: name.isEmpty ? nil : name)
        machines.session(machineID)?.machine.displayName = name.isEmpty ? nil : name
    }

    func signOut() async {
        dropAllMachines()
        if let hub { await hub.revoke() }
        await auth.signOut()
    }
}
