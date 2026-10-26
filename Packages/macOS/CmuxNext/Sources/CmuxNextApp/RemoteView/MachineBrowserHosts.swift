import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import CmuxNextWakeups
import Foundation

/// Which machines run browser tabs there (cx-2cob slice 2): the last
/// `browser-runtime-status` of each machine's daemon connection, read when
/// that connection appears and after a start. The placement rule asks
/// `available(_:)`, a cached answer that never waits.
@MainActor
final class MachineBrowserHosts {
    private let machines: MachineRegistry
    /// The app's remote localhost, made on first use (a machine connected, a browser started there).
    private let localhost: @MainActor () -> RemoteLocalhostService?
    /// The last status by machine, for the daemon connection it came from.
    private var known: [String: (connection: ObjectIdentifier, status: BrowserRuntimeStatus?)] = [:]
    private var probing: Set<String> = []
    /// The app's main-thread scheduler: each status answer is a task on it.
    private let mainWork: MainWorkScheduler
    /// The remote machines' connections: a new one is checked once (a service observation: the placement rule asks
    /// whether or not anything shows).
    private var observation: ServiceObservation<[MachineLink]>?

    /// One remote machine's daemon and its connection now, by identity: a dropped and remade connection, or one
    /// replaced by another, is a new value, so the status is read again for it.
    nonisolated struct MachineLink: Equatable, Sendable {
        let machine: String
        let connection: ObjectIdentifier?

        init(machine: String, connection: AnyObject?) {
            self.machine = machine
            self.connection = connection.map { ObjectIdentifier($0) }
        }
    }

    init(machines: MachineRegistry, mainWork: MainWorkScheduler, localhost: @escaping @MainActor () -> RemoteLocalhostService?) {
        self.machines = machines
        self.mainWork = mainWork
        self.localhost = localhost
        #if DEBUG
        observation = ServiceObservation(.visible, owner: "MachineBrowserHosts.links", on: mainWork) {
            machines.daemons.filter { !$0.isLocal }.map { MachineLink(machine: $0.machineID, connection: $0.connection) }
        } apply: { [weak self] links in
            for link in links where link.connection != nil && self?.installed(link.machine) == nil { self?.refresh(link.machine) }
        }
        #endif
    }

    /// The machine runs browser tabs: its daemon has `browser-runtime-v1`
    /// and a browser is installed. Release builds: never yet (slice 2 D).
    func available(_ machine: String) -> Bool {
        #if DEBUG
        guard let connection = connection(of: machine), let entry = known[machine], entry.connection == connection else { return false }
        return entry.status?.installed != nil
        #else
        return false
        #endif
    }

    /// The last answer: installed, not installed, or unknown (nil).
    func installed(_ machine: String) -> Bool? {
        guard let connection = connection(of: machine), let entry = known[machine], entry.connection == connection else { return nil }
        return entry.status?.installed != nil
    }

    /// Reads the machine's status again (a new connection, Retry).
    func refresh(_ machine: String) {
        guard let connection = connection(of: machine), let client = localhost()?.loopbackClient(machine: machine),
              !probing.contains(machine) else { return }
        probing.insert(machine)
        let mainWork = mainWork
        // task-owner: one status read off the main thread; ends with its answer, one visible task (the placement rule reads it).
        Task { @concurrent [weak self] in
            let status = try? await client.browserRuntimeStatus()
            mainWork.postFromAnyThread(.visible, owner: "MachineBrowserHosts.status") { [weak self] in
                self?.probed(machine, on: connection, status: status)
            }
        }
    }

    /// A status read ended: kept for the connection it was read on. A connection that replaced that one while it
    /// read is read now (its links change came while the read held `probing`).
    private func probed(_ machine: String, on connection: ObjectIdentifier, status: BrowserRuntimeStatus?) {
        probing.remove(machine)
        known[machine] = (connection, status)
        if let current = self.connection(of: machine), current != connection { refresh(machine) }
    }

    /// Starts a browser on the machine; the answer updates `available`.
    func start(_ machine: String, url: URL?) async -> Result<BrowserRuntime, BrowserRuntimeError> {
        guard let connection = connection(of: machine), let client = localhost()?.loopbackClient(machine: machine) else {
            return .failure(.unavailable(machine))
        }
        do {
            let runtime = try await client.startBrowserRuntime(url: url)
            known[machine] = (connection, BrowserRuntimeStatus(installed: runtime.installed, platform: known[machine]?.status?.platform ?? ""))
            return .success(runtime)
        } catch {
            if error == .notInstalled { known[machine] = (connection, BrowserRuntimeStatus(installed: nil, platform: "")) }
            return .failure(error)
        }
    }

    /// The tab of `runtime` closed: the machine stops its browser.
    func stop(_ machine: String, runtime: UInt64) {
        guard let client = localhost()?.loopbackClient(machine: machine) else { return }
        // task-owner: one stop request; ends with its answer. Nothing in it runs on the main thread.
        Task { @concurrent in await client.stopBrowserRuntime(runtime) }
    }

    private func connection(of machine: String) -> ObjectIdentifier? {
        machines.daemon(machine: machine)?.connection.map { ObjectIdentifier($0) }
    }
}
