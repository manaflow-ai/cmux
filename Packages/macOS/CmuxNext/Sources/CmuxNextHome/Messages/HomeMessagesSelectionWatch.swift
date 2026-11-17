public import CmuxHomeCore
import CmuxNextCompat

/// The Messages page's follow of the host's pending selection (`HomeService.pendingSelection`: a
/// conversation a sheet, the CLI, a run or New Message's first send started): once the inbox lists
/// it, the page shows it and the request is spent. New Message's first send publishes its
/// conversation only after the send's outcome is known (``HomeMessagesFirstSend``), so a refusal
/// never moves the page off New Message.
@MainActor
public struct HomeMessagesSelectionWatch {
    private let pending: @MainActor @Sendable () -> ConversationID?
    private let spend: @MainActor @Sendable () -> Void
    private let rows: @MainActor @Sendable () -> [ConversationID]

    /// `pending` reads the request, `spend` clears it, `rows` lists the inbox's conversations.
    public init(pending: @escaping @MainActor @Sendable () -> ConversationID?,
                spend: @escaping @MainActor @Sendable () -> Void,
                rows: @escaping @MainActor @Sendable () -> [ConversationID]) {
        self.pending = pending
        self.spend = spend
        self.rows = rows
    }

    /// Shows each pending conversation once the inbox lists it; the caller cancels the task.
    public func follow(show: @escaping @MainActor (ConversationID) -> Void) -> Task<Void, Never> {
        let pending = pending, spend = spend, rows = rows
        // task-owner: the caller's (HomeMessagesPage cancels it in deinit); event-driven (Observation)
        return Task {
            for await (id, listed) in ObservationStream({ (pending(), rows()) }) {
                guard let id, listed.contains(id) else { continue }
                spend()
                show(id)
            }
        }
    }
}
