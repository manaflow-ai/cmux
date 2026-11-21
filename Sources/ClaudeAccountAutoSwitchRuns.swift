import CmuxAgentJournal
import Foundation

/// The automatic Claude account switches running now: at most one per pane, each a stored task,
/// and the pane's Claude events seen while it runs.
///
/// A run is cancelled when its pane closes (``cancel(panelId:)``) or when this object goes away.
/// A cancelled run keeps its pane until its task has unwound, so two runs for one pane never
/// overlap. Its state is cleared when its task returns, cancelled or not.
@MainActor
final class ClaudeAccountAutoSwitchRuns {
    /// A Claude event of the pane, seen while its switch runs.
    struct Event: Equatable, Sendable {
        let kind: AgentJournalEventKind
        let sessionId: String?
        let occurredAtMs: Int64
    }

    private struct Run {
        let id: UUID
        let task: Task<Void, Never>
        var events: [Event] = []
    }

    private var runs: [UUID: Run] = [:]

    deinit {
        runs.values.forEach { $0.task.cancel() }
    }

    /// Whether no pane has a run.
    var isEmpty: Bool { runs.isEmpty }

    func isRunning(panelId: UUID) -> Bool {
        runs[panelId] != nil
    }

    /// Starts `operation` as the pane's run and returns its task; `nil`, without starting
    /// anything, while the pane already has one.
    @discardableResult
    func start(panelId: UUID, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard runs[panelId] == nil else { return nil }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            // Runs however the operation ends, cancelled or not, and leaves a newer run alone.
            defer { self?.end(panelId: panelId, id: id) }
            await operation()
        }
        runs[panelId] = Run(id: id, task: task)
        return task
    }

    /// Records `event` for the pane's run; ignored while the pane has none.
    func record(_ event: Event, panelId: UUID) {
        runs[panelId]?.events.append(event)
    }

    /// The events recorded for the pane's run, oldest first.
    func events(panelId: UUID) -> [Event] {
        runs[panelId]?.events ?? []
    }

    /// Cancels the pane's run, if any. The run still holds the pane until its task returns.
    func cancel(panelId: UUID) {
        runs[panelId]?.task.cancel()
    }

    private func end(panelId: UUID, id: UUID) {
        if runs[panelId]?.id == id { runs[panelId] = nil }
    }
}
