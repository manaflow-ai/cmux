import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Observation
import os

/// Terminal command history (plans/cmux-next/history.md 2, `command`): keeps
/// each connected daemon's `terminal-command-journal-v1` switch equal to
/// `history.terminalCommands` (off by default), and folds the daemons'
/// `shell.command.finished` journal records when a history list asks.
final class CommandHistory {
    private unowned let services: AppServices
    let hidden: HiddenHistoryStore
    private var folds: [String: TerminalCommandFold] = [:]
    private var generations: [String: String] = [:]
    private var refreshing: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    /// The switch each connected daemon was last sent, by machine and boot
    /// generation (a restarted daemon starts off and is told again).
    private var sent: [String: (generation: String, enabled: Bool)] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    init(services: AppServices, hidden: HiddenHistoryStore) {
        self.services = services
        self.hidden = hidden
    }

    deinit { observation?.cancel() }

    /// Starts keeping the daemons' switch in step with the setting.
    func start(settings: SettingsController) {
        let machines = services.machines
        observation = Task { [weak self] in
            for await state in Observations({ Self.state(settings: settings, daemons: machines.daemons) }) {
                self?.sync(state)
            }
        }
    }

    private struct SyncState: Sendable, Equatable {
        var enabled: Bool
        /// Connected machines that serve the capability, with their boot generation.
        var machines: [String: String]
    }

    private static func state(settings: SettingsController, daemons: [DaemonService]) -> SyncState {
        var machines: [String: String] = [:]
        for daemon in daemons where daemon.supports(DaemonCapabilities.shared.terminalCommandJournal) {
            guard case .connected = daemon.store.connectionState else { continue }
            machines[daemon.machineID] = daemon.store.generation?.rawValue ?? ""
        }
        return SyncState(enabled: settings.snapshot.recordsTerminalCommands, machines: machines)
    }

    private func sync(_ state: SyncState) {
        for (machine, generation) in state.machines {
            if let last = sent[machine], last.generation == generation, last.enabled == state.enabled { continue }
            // A daemon starts with history off: nothing to send to turn it off.
            if sent[machine]?.generation != generation, !state.enabled {
                sent[machine] = (generation, false)
                continue
            }
            guard let daemon = services.machines.daemons.first(where: { $0.machineID == machine }) else { continue }
            sent[machine] = (generation, state.enabled)
            let enabled = state.enabled
            daemon.send("set-terminal-command-history") { connection in
                try await connection.setTerminalCommandHistory(enabled: enabled)
            }
        }
        sent = sent.filter { state.machines[$0.key] != nil }
    }

    // MARK: Reading

    /// Reads new command records from every connected machine that serves
    /// the capability. Concurrent calls share one read.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readAll() async {
        for daemon in services.machines.daemons where daemon.supports(DaemonCapabilities.shared.terminalCommandJournal) {
            guard case .connected = daemon.store.connectionState, let endpoint = try? await daemon.endpoint() else { continue }
            let machine = daemon.machineID
            let fold = folds[machine] ?? TerminalCommandFold(machine: machine)
            let cursor = generations[machine].map { (generation: $0, sequence: fold.cursor) }
            do {
                let result = try await SessionJournalRead.shared.read(socketPath: endpoint.socketPath, kinds: [TerminalCommandFold.journalKind],
                                                               cursor: fold.cursor > 0 ? cursor : nil)
                var next = fold
                if let generation = result.generation, let known = generations[machine], known != generation {
                    next = TerminalCommandFold(machine: machine)
                }
                let decoder = JSONDecoder()
                next.apply(result.records.compactMap { try? decoder.decode(CommandJournalRecord.self, from: $0) })
                folds[machine] = next
                if let generation = result.generation { generations[machine] = generation }
            } catch {
                logger.info("command history: journal read on \(machine, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                generations[machine] = nil
                folds[machine] = nil
            }
        }
    }

    func entries() -> [HistoryEntry] {
        folds.values.flatMap(\.commands)
            .filter { !hidden.document.hides($0.qualifiedID, activeAt: $0.startedAt, kind: "command") }
            .map { command in
                let connected = services.machines.daemons.contains { $0.machineID == command.machine }
                return HistoryEntry(
                    id: "command:\(command.qualifiedID)", kind: .command, time: command.startedAt,
                    title: command.command ?? HistoryAppStrings.unknownCommand, detail: command.cwd,
                    machineName: command.machine == MachineRegistry.localID ? nil : command.machine,
                    isAvailable: connected, payload: .command(command))
            }
    }

    func hide(since: Date?) {
        hidden.change { $0.hide(since: since, now: Date(), kind: "command") }
    }

    func hide(_ command: TerminalCommand) {
        hidden.change { $0.hide(entry: command.qualifiedID) }
    }
}
