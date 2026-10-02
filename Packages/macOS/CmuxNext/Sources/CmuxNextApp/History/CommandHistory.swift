import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Observation
import os

/// Terminal command history (plans/cmux-next/history.md 2, `command`). The
/// daemons own the commands (`terminal-command-history-v1`: deletable rows
/// with a retention); this keeps each connected daemon's switch and
/// retention equal to `history.terminalCommands` (off by default) and
/// `history.commandRetentionDays` (30), mirrors the rows for history lists,
/// and deletes rows in the daemon when the user removes or clears them.
/// Turning recording off offers to delete what was already recorded.
final class CommandHistory {
    private unowned let services: AppServices
    private var mirrors: [String: TerminalCommandMirror] = [:]
    private var refreshing: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    /// What each connected daemon was last sent, by machine; a restarted
    /// daemon (new boot generation) starts with recording off and is told again.
    private var sent: [String: Sent] = [:]
    private var lastEnabled: Bool?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    private struct Sent: Equatable {
        var generation: String
        var enabled: Bool
        var retentionDays: Int
    }

    init(services: AppServices) {
        self.services = services
    }

    deinit { observation?.cancel() }

    /// Starts keeping the daemons' switch and retention in step with the settings.
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
        var retentionDays: Int
        /// Connected machines that serve the capability, with their boot generation.
        var machines: [String: String]
    }

    private static func state(settings: SettingsController, daemons: [DaemonService]) -> SyncState {
        var machines: [String: String] = [:]
        for daemon in daemons where daemon.supports(DaemonCapabilities.shared.terminalCommandHistory) {
            guard case .connected = daemon.store.connectionState else { continue }
            machines[daemon.machineID] = daemon.store.generation?.rawValue ?? ""
        }
        return SyncState(enabled: settings.snapshot.recordsTerminalCommands,
                         retentionDays: settings.snapshot.commandRetentionDays, machines: machines)
    }

    private func sync(_ state: SyncState) {
        if lastEnabled == true, !state.enabled { offerDeletion(retentionDays: state.retentionDays) }
        lastEnabled = state.enabled
        for (machine, generation) in state.machines {
            let next = Sent(generation: generation, enabled: state.enabled, retentionDays: state.retentionDays)
            // Sent on every connect, off too: the retention reaches the daemon.
            guard sent[machine] != next,
                  let daemon = services.machines.daemons.first(where: { $0.machineID == machine }) else { continue }
            sent[machine] = next
            daemon.send("set-terminal-command-history") { connection in
                try await connection.setTerminalCommandHistory(enabled: next.enabled, retentionDays: next.retentionDays)
            }
        }
        sent = sent.filter { state.machines[$0.key] != nil }
    }

    /// Recording was turned off: ask whether to delete what the connected
    /// machines already recorded. Without a window nobody is asked and
    /// nothing is deleted.
    private func offerDeletion(retentionDays: Int) {
        let prompt = DestructiveConfirmation.Prompt(title: HistoryAppStrings.deleteCommandsTitle,
                                                    body: HistoryAppStrings.deleteCommandsBody(retentionDays),
                                                    button: HistoryAppStrings.deleteCommandsButton)
        DestructiveConfirmation.present(prompt, in: services.windows.active?.window) { [weak self] delete in
            if delete { self?.delete(since: nil) }
        }
    }

    // MARK: Reading

    /// Reads new command rows from every connected machine that serves the
    /// capability. Concurrent calls share one read.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readAll() async {
        for daemon in daemons() {
            guard let connection = daemon.connection else { continue }
            let machine = daemon.machineID
            var mirror = mirrors[machine] ?? TerminalCommandMirror(machine: machine)
            do {
                // A second read only when appending after the cursor was wrong.
                for _ in 0..<2 {
                    let after = mirror.cursor
                    let page = try await connection.request(ListTerminalCommandsRequest(afterID: after.map(String.init)))
                    let expired = Date().addingTimeInterval(-TimeInterval(page.retentionDays) * 86_400)
                    if mirror.apply(page.commands.compactMap { Self.command($0, machine: machine) }, version: page.version,
                                    truncated: page.truncated, after: after, expiredThrough: expired) {
                        break
                    }
                }
                mirrors[machine] = mirror
            } catch {
                logger.info("command history: list on \(machine, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                mirrors[machine] = nil
            }
        }
    }

    static func command(_ row: TerminalCommandRow, machine: String) -> TerminalCommand? {
        guard let id = UInt64(row.id), let started = Int64(row.startedAtMs) else { return nil }
        return TerminalCommand(id: id, machine: machine, terminal: row.terminalID, command: row.command, cwd: row.cwd,
                               exitCode: row.exitCode, startedAt: Date(timeIntervalSince1970: TimeInterval(started) / 1000),
                               duration: Double(row.durationMs).map { $0 / 1000 })
    }

    func entries() -> [HistoryEntry] {
        mirrors.values.flatMap(\.commands).map { command in
            let connected = services.machines.daemons.contains { $0.machineID == command.machine }
            return HistoryEntry(
                id: "command:\(command.qualifiedID)", kind: .command, time: command.startedAt,
                title: command.command ?? HistoryAppStrings.unknownCommand, detail: command.cwd,
                machineName: command.machine == MachineRegistry.localID ? nil : command.machine,
                isAvailable: connected, payload: .command(command))
        }
    }

    // MARK: Deleting

    /// Deletes, in every connected daemon, the commands that started at or
    /// after `since` (nil: all).
    func delete(since: Date?) {
        for machine in mirrors.keys { mirrors[machine]?.remove(startedSince: since) }
        let selection: DeleteTerminalCommandsRequest.Selection = since.map { .startedSince($0) } ?? .all
        for daemon in daemons() {
            daemon.send("delete-terminal-commands") { _ = try await $0.request(DeleteTerminalCommandsRequest(selection)) }
        }
    }

    /// Deletes one command in its daemon.
    func delete(_ command: TerminalCommand) {
        mirrors[command.machine]?.remove(ids: [command.id])
        guard let daemon = daemons().first(where: { $0.machineID == command.machine }) else { return }
        let id = String(command.id)
        daemon.send("delete-terminal-commands") { _ = try await $0.request(DeleteTerminalCommandsRequest(.ids([id]))) }
    }

    private func daemons() -> [DaemonService] {
        services.machines.daemons.filter { daemon in
            guard daemon.supports(DaemonCapabilities.shared.terminalCommandHistory), case .connected = daemon.store.connectionState else { return false }
            return true
        }
    }
}
