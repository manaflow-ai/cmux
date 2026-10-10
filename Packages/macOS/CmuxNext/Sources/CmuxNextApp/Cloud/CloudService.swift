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
    /// This Mac's Cloud install principal (cx-wb5.64): install tokens for the
    /// credential relay; registered at sign-in, revoked at sign-out.
    @ObservationIgnored let installIdentity: MacInstallIdentity
    @ObservationIgnored private let machines: MachineRegistry
    @ObservationIgnored private let binary: URL?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    /// The local side event subscription for `cloud.link.changed` (app link).
    @ObservationIgnored private var linkEvents: UInt64?
    /// The `credential` provider family on the local daemon (cx-wb5.63):
    /// app servers' Cloud API calls, sent with the install token.
    @ObservationIgnored private var credentialProvider: CloudCredentialProvider?
    @ObservationIgnored private var credentialEvents: UInt64?
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    /// The last list or connection failure, for diagnostics and refusals.
    private(set) var lastError: String?
    private(set) var hasLoadedMachines = false
    /// The Cloud app server's ops on the local daemon (contract 2.1).
    var appOps: CloudAppOp { CloudAppLinks.ops(local: machines.local) }
    /// The cmux window a create's native confirmation attaches to (set by AppServices).
    @ObservationIgnored var confirmWindow: (@MainActor () -> NSWindow?)?
    /// Machine creations in flight (sidebar can show a placeholder).
    private(set) var creating = 0
    /// New Cloud Workspace runs from the click to the open terminal: each
    /// window's progress view and sidebar row (cx-lu8f).
    let creations = CloudCreations()

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
        installIdentity = MacInstallIdentity(
            store: .forApp(directory: paths.root.appendingPathComponent("install", isDirectory: true),
                           service: "\(configuration.bundleID ?? "cmux").install-key.\(configuration.ownerAPIBaseURL().host ?? "unknown")",
                           team: CodeSigningTeam.current(), isDebugBuild: configuration.isDebugBuild),
            transport: InstallHTTPTransport(baseURL: configuration.ownerAPIBaseURL()),
            deviceName: Self.deviceName,
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let identity = installIdentity
        let transport = InstallHTTPTransport(baseURL: configuration.ownerAPIBaseURL())
        let clientHeaders = identity.requestHeaders
        credentialProvider = CloudCredentialProvider(relay: CloudCredentialRelay(
            post: { path, body, bearer in try await transport.post(path, json: body, bearer: bearer, headers: clientHeaders) },
            token: { try await identity.installToken() },
            invalidate: { await identity.invalidate() },
            // The team is the backend team the relay bills: the install
            // token's team claim (never the Stack team id) (cx-i6g4).
            session: { [auth] in
                guard await MainActor.run(body: { auth.isSignedIn }) else { return CloudCredentialRelay.Session(signedIn: false, team: nil) }
                let token = try? await identity.installToken()
                return CloudCredentialRelay.Session(signedIn: true, team: token.flatMap(CloudService.team(ofToken:)))
            }
        ))
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

    func localDeviceID() throws -> String { try paths.loadOrCreateDeviceID() }

    var isSignedIn: Bool { auth.isSignedIn }

    /// Why Cloud cannot run in this build, or nil.
    var unavailableReason: String? {
        if policyDisabled { return RefusalStrings.turnedOffByOrganization }
        // RestrictToManagedTeam (P17-3): no request goes out without the managed team.
        if auth.managedTeamID != nil, auth.teamID == nil { return RefusalStrings.turnedOffByOrganization }
        // The app server path needs no web backend (cx-t2rz): only the legacy /api/vm path does.
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return CloudStrings.localBackend }
        if binary == nil { return CloudStrings.noClient }
        return nil
    }

    /// Whether a Cloud API request may go out: not turned off by the
    /// organization, the managed team present (P17-3), not a local-only
    /// backend. (A missing cmux-tui client blocks machines, not the API.)
    var mayCallCloud: Bool {
        if policyDisabled { return false }
        if auth.managedTeamID != nil, auth.teamID == nil { return false }
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return false }
        return true
    }

    func start() {
        auth.start()
        startCredentialProvider()
        if configuration.linkSource == .appServer, linkEvents == nil {
            // `cloud.link.changed` arrives on the local daemon as an app server event.
            let machines = machines
            linkEvents = machines.local.store.sideEvents.subscribe { event in
                guard let change = CloudAppLinks.change(in: event) else { return }
                machines.session(change.key.machine)?.linkChanged(change)
            }
            // task-owner: observers; cancelled in stop()
            observers.append(Task {
                // A reconnected local connection is a new daemon client: subscribe it again.
                for await state in Observations({ machines.local.store.connectionState }) {
                    guard case .connected = state, machines.cloud.contains(where: { $0.appLink != nil }) else { continue }
                    await CloudAppLinks.resubscribe(local: machines.local)
                }
            })
        }
        observers.append(Task { [weak self] in
            guard let self else { return }
            await auth.awaitRestored()
            for await signedIn in Observations({ self.auth.isSignedIn }) {
                if signedIn {
                    // Sign-out revoked the WireGuard peer and parked the hub.
                    await self.hub?.resume()
                    await self.refresh()
                    await self.installSignedIn()
                } else {
                    self.dropAllMachines()
                    await self.installIdentity.unbind()
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

    /// Set while an administrator turned Cloud off (`DisabledFeatures`).
    private(set) var policyDisabled = false

    /// Turning Cloud off disconnects every machine and keeps its workspaces
    /// (their terminals show "Turned off by your organization"); the VMs
    /// keep running. Turning it on again reconnects from a fresh list.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        if disabled {
            for session in machines.cloud {
                session.daemon.policyBlock.set(true)
                session.disconnect()
            }
            // The local tunnel hub stops too; nothing is revoked remotely.
            // task-owner: one teardown hop; hub.stop() is idempotent
            if let hub { Task { await hub.stop() } }
        } else {
            dropAllMachines()
            // task-owner: one list fetch after the policy lifted
            Task { [weak self] in
                guard let self, auth.isSignedIn else { return }
                await hub?.resume()
                await refresh()
                await installSignedIn()
            }
        }
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        if let linkEvents { machines.local.store.sideEvents.unsubscribe(linkEvents) }
        linkEvents = nil
        if let credentialEvents { machines.local.store.sideEvents.unsubscribe(credentialEvents) }
        credentialEvents = nil
        credentialProvider?.stop()
        for session in machines.cloud { session.disconnect() }
        // task-owner: teardown hop at quit; hub.stop() is idempotent
        if let hub { Task { await hub.stop() } }
    }

    /// Serves the `credential` family on the local daemon: answers its
    /// calls on the connection that sent them, and registers again after
    /// every handshake of the verified app connection (a reconnected
    /// connection is a new provider; its calls in flight ended with it).
    /// Only the app server path uses it: with the legacy link (the release
    /// and default Debug path) the relay never registers.
    private func startCredentialProvider() {
        guard configuration.linkSource == .appServer, let provider = credentialProvider, credentialEvents == nil else { return }
        let local = machines.local
        credentialEvents = local.store.sideEvents.subscribe { [weak local] event in
            guard let connection = local?.connection else { return }
            provider.handle(event) { result in _ = try await connection.request(result) }
        }
        // task-owner: observers; cancelled in stop()
        observers.append(Task {
            for await state in Observations({ local.store.connectionState }) {
                guard case .connected = state, let connection = local.connection else { continue }
                provider.stop()
                let allowed = await connection.userOriginAllowed
                _ = await CloudCredentialProvider.register(userOriginAllowed: allowed) { try await connection.request($0) }
            }
        })
    }

    // MARK: Machine list

    /// Fetches `/api/vm` and reconciles sessions: new live machines connect,
    /// gone machines disconnect, records update in place.
    func refresh() async {
        guard auth.isSignedIn, unavailableReason == nil else { return }
        lastRefresh = .now
        do {
            let list = configuration.linkSource == .appServer ? try await appServerMachines() : try await api.listMachines()
            lastError = nil
            reconcile(list)
            hasLoadedMachines = true
        } catch {
            lastError = String(describing: error)
            logger.error("machine list failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func reconcile(_ list: [CloudMachine]) {
        // A list that arrives after Cloud was turned off connects nothing.
        guard !policyDisabled else { return }
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
            creations.machineRemoved(session.machineID)
            machines.remove(session.machineID)?.disconnect()
        }
    }

    @discardableResult
    private func addSession(_ machine: CloudMachine) -> CloudMachineSession? {
        guard !policyDisabled else { return nil }
        let session: CloudMachineSession
        switch configuration.linkSource {
        case .appServer:
            let resolver = CloudConnectOpResolver(run: CloudAppLinks.runner(local: machines.local))
            let local = machines.local
            session = CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                          localIdentity: { [weak local] in local?.identity })
        case .legacy:
            guard let hub, let binary else { return nil }
            let link = CloudMachineLink(machineID: machine.id, api: api, hub: hub, paths: paths, binary: binary, deviceName: Self.deviceName)
            session = CloudMachineSession(machine: machine, link: link)
        }
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        session.connect()
        return session
    }

    private func dropAllMachines() {
        for creation in creations.all { creations.remove(creation) }
        for session in machines.cloud { machines.remove(session.machineID)?.disconnect() }
        hasLoadedMachines = false
    }

    // MARK: Mutations

    /// Creates a machine and connects to it. Returns its session.
    /// `creation` moves to its `creating` stage when the request is sent.
    /// `startedByPerson`: the person's own gesture in this app; on the app
    /// server path any other create asks the person first
    /// (``CloudMachineCreateFlow``).
    func createMachine(name: String?, creation: CloudMachineCreation? = nil, startedByPerson: Bool) async throws -> CloudMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        guard auth.isSignedIn else { throw ActionFailure(message: CloudStrings.signInFirst) }
        creating += 1
        defer { creating -= 1 }
        let onSent: @MainActor @Sendable () async -> Void = { [weak creation] in creation?.note(.creating) }
        let machine = configuration.linkSource == .appServer
            ? try await appServerCreate(name: name, startedByPerson: startedByPerson, onSent: onSent)
            : try await api.createMachine(displayName: name, onSent: onSent)
        logger.info("created machine \(machine.id, privacy: .public)")
        if let existing = machines.session(machine.id) { return existing }
        guard let session = addSession(machine) else { throw ActionFailure(message: CloudStrings.noClient) }
        return session
    }

    func deleteMachine(_ machineID: String) async throws {
        try await api.deleteMachine(machineID)
        creations.machineRemoved(machineID)
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
        // Revoke the install while the Stack session still exists.
        if let stackUser = auth.user?.id {
            let auth = auth
            await installIdentity.signOut(stackUser: stackUser, session: { try await auth.tokens().access })
        }
        await auth.signOut()
    }

    /// Registers (or reuses) this Mac's install for the signed-in user and
    /// mints one token. A failure is logged: the relay mints again when it
    /// needs a token, and the hub path does not depend on it.
    private func installSignedIn() async {
        guard let stackUser = auth.user?.id, mayCallCloud else { return }
        let auth = auth
        do {
            try await installIdentity.signedIn(stackUser: stackUser, session: { try await auth.tokens().access })
        } catch {
            logger.error("install registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}
