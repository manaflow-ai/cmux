import CmuxNextWakeups

/// Settings > Agents > Keep Chats Running When This Mac Sleeps: the app's will-sleep notice (the
/// observer FeedService already has) goes to this app's acpmux as `_acpmux/sleep_handoff`. Wiring
/// only: acpmux reads the setting and decides which chats move and where (cmux-tui acpmux
/// `cli/run/sleep_handoff.rs`), and answers before it moves anything, so the sleep never waits on
/// the moves.
public nonisolated struct AcpmuxSleepHandoff: Sendable {
    /// How long the notice waits for the daemon's answer, which comes before any move starts.
    static let answerDeadline: Duration = .seconds(5)
    let socketPath: String?

    /// `socketPath`: this app's daemon socket (nil: none, so no chat runs here to move).
    public init(socketPath: String?) { self.socketPath = socketPath }

    /// Sends the notice and returns at once.
    public func notify() {
        guard let socketPath else { return }
        // task-owner: one request per will-sleep notice; ends at the daemon's answer or the deadline.
        Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
            _ = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/sleep_handoff", deadline: Self.answerDeadline)
        }
    }
}
