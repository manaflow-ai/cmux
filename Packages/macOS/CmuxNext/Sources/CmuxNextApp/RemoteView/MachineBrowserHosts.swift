import CmuxNextDaemon
import Foundation

/// Which machines run browser tabs there (cx-2cob slice 2): the last
/// `browser-runtime-status` of each machine's daemon connection, read when
/// that connection appears and after a start. The placement rule asks
/// `available(_:)`, a cached answer that never waits.
@MainActor
final class MachineBrowserHosts {
    private let machines: MachineRegistry
    private let localhost: RemoteLocalhostService
    /// The last status by machine, for the daemon connection it came from.
    private var known: [String: (connection: ObjectIdentifier, status: BrowserRuntimeStatus?)] = [:]
    private var probing: Set<String> = []
    private var observation: Task<Void, Never>?

    init(machines: MachineRegistry, localhost: RemoteLocalhostService) {
        self.machines = machines
        self.localhost = localhost
        // task-owner: lives as long as the app; event-driven (Observation): a machine's new connection is checked
        // once, and a forgotten machine's forwarding connection closes (its browser runtimes stop with it).
        observation = Task { [weak self, machines, localhost] in
            for await links in Observations({ machines.daemons.filter { !$0.isLocal }.map { ($0.machineID, $0.connection != nil) } }) {
                localhost.closeClientsOfRemovedMachines()
                #if DEBUG
                for (machine, connected) in links where connected && self?.installed(machine) == nil { self?.refresh(machine) }
                #else
                _ = (links, self)
                #endif
            }
        }
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
        guard let connection = connection(of: machine), let client = localhost.loopbackClient(machine: machine),
              !probing.contains(machine) else { return }
        probing.insert(machine)
        // task-owner: one status read; ends with its answer.
        Task { [weak self] in
            let status = try? await client.browserRuntimeStatus()
            self?.probing.remove(machine)
            self?.known[machine] = (connection, status)
        }
    }

    /// Starts a browser on the machine; the answer updates `available`.
    func start(_ machine: String, url: URL?) async -> Result<BrowserRuntime, BrowserRuntimeError> {
        guard let connection = connection(of: machine), let client = localhost.loopbackClient(machine: machine) else {
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
        guard let client = localhost.loopbackClient(machine: machine) else { return }
        // task-owner: one stop request; ends with its answer.
        Task { await client.stopBrowserRuntime(runtime) }
    }

    private func connection(of machine: String) -> ObjectIdentifier? {
        machines.daemon(machine: machine)?.connection.map { ObjectIdentifier($0) }
    }
}
