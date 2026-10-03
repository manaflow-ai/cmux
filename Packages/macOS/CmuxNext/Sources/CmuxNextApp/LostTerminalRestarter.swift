import CmuxNextDaemon
import CmuxNextSettings
import Observation

/// `terminal.restartLostTerminals` (user decision 2026-10-02,
/// plans/cmux-next/ownership.md 3.2): while it is on, every dead local
/// terminal tab of every connected daemon that serves `tab-restart-v1` gets
/// `restart-tab {only_lost}`, keyed by its dead terminal
/// (`TabRestart.idempotencyKey`), so this client, a manual Restart and
/// other clients never restart one terminal twice. The daemon decides: it
/// restarts only a host loss and refuses a process that ended on its own.
/// Event-driven: it looks again when the setting, a connection or a tab's
/// `dead` changes (a reconnect, or a host lost while connected).
final class LostTerminalRestarter {
    struct Candidate: Hashable, Sendable {
        var machine: String
        var surface: SurfaceID
        var key: String
        var cwd: String?
    }

    private unowned let services: AppServices
    private var observation: Task<Void, Never>?
    /// Keys sent for the current candidates; a terminal that dies again has
    /// a new key.
    private var sent: Set<String> = []

    init(services: AppServices) {
        self.services = services
    }

    deinit { observation?.cancel() }

    func start(settings: SettingsController) {
        let machines = services.machines
        observation = Task { [weak self] in
            for await candidates in Observations({ Self.candidates(enabled: settings.snapshot.restartsLostTerminals,
                                                                   daemons: machines.daemons) }) {
                self?.restart(candidates)
            }
        }
    }

    static func candidates(enabled: Bool, daemons: [DaemonService]) -> [Candidate] {
        guard enabled else { return [] }
        var found: [Candidate] = []
        for daemon in daemons where daemon.supports(DaemonCapabilities.shared.tabRestart) {
            guard case .connected = daemon.store.connectionState else { continue }
            let tabs = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            found += candidates(machine: daemon.machineID, tabs: tabs)
        }
        return found
    }

    /// The tabs to try: dead local terminal tabs. A keep-layout tab (it has
    /// a `relaunch` record) restarts through the kept-layout relaunch.
    static func candidates(machine: String, tabs: [TabModel]) -> [Candidate] {
        tabs.filter { TabRestart.isRestartable($0) && $0.snapshot.relaunch == nil }.map { tab in
            Candidate(machine: machine, surface: tab.surface,
                      key: TabRestart.idempotencyKey(tab), cwd: tab.cwd)
        }
    }

    private func restart(_ candidates: [Candidate]) {
        // Keys of tabs that are no longer candidates (restarted, closed, or
        // their daemon disconnected) go, so a reconnect tries again.
        sent.formIntersection(candidates.map(\.key))
        for candidate in candidates where sent.insert(candidate.key).inserted {
            guard let daemon = services.machines.daemons.first(where: { $0.machineID == candidate.machine }) else { continue }
            daemon.send("restart-tab") { connection in
                try await connection.restartTab(candidate.surface, idempotencyKey: candidate.key,
                                                fallbackCwd: candidate.cwd, onlyLost: true)
            }
        }
    }
}
