import Foundation

/// A read the person made on the phone (a Feed event, Mark Workspace as Read, Mark All
/// Notifications as Read), sent until the Mac's daemon answers it, as the Mac's own `TabReads`
/// does (Leo, 2026-11-09: "the other thing is that for some reason the dot isn't disappearing in
/// my case... but i guess the current nightly still hasn't fixed/restarted the service?"). The
/// phone shows the read at once (its Feed read marks, the row's `seenAt`). A Mac whose daemon is
/// down, restarting or still restoring has not refused it: no bound `daemon` channel, a channel
/// that closed, a reply past its deadline. The write goes again, spaced 0.25 s doubling to 5 s, so
/// it lands within one spacing of the daemon coming back, on whichever connection is bound then.
/// Only the daemon's own refusal (`DaemonReplyError`) ends it unsent.
///
/// Each write stops at its answer, at a refusal, or once its read no longer stands (`stands`): the
/// Mac's record settled it (read, or a newer notification the person has not seen), the person
/// changed it, or the Mac went away from this phone.
@MainActor
struct StickyRead {
    static let initial: Duration = .milliseconds(250)
    static let maximum: Duration = .seconds(5)

    /// Waits out one spacing; tests replace it.
    var pause: @MainActor (Duration) async -> Void = { delay in try? await Task.sleep(for: delay) }

    /// Whether `error` leaves the write's outcome unknown, so sending it again can tell: anything
    /// but the daemon's refusal.
    nonisolated static func isUnanswered(_ error: any Error) -> Bool { !(error is DaemonReplyError) }

    /// The spacing after `delay`: doubled, at most `maximum`.
    nonisolated static func next(after delay: Duration) -> Duration { min(delay * 2, maximum) }

    /// Sends `attempt` until it is answered while `stands()` holds. Returns its reply, or nil once
    /// the read no longer stands (or the task was cancelled); throws the daemon's refusal.
    func send<T>(stands: () -> Bool, _ attempt: () async throws -> T) async throws -> T? {
        var delay = Self.initial
        while stands(), !Task.isCancelled {
            do {
                return try await attempt()
            } catch where Self.isUnanswered(error) {
                await pause(delay)
                delay = Self.next(after: delay)
            }
        }
        return nil
    }
}
