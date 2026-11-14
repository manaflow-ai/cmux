package import CmuxNextHistory

/// Where the session vault reads past agent sessions from. The app reads each
/// machine's session journal (``AgentHistorySource``); tests pass fixed sessions.
@MainActor
package protocol VaultSessionSource: AnyObject {
    /// Reads what is new since the last call (no polling between calls).
    func refresh() async
    /// Every known session, newest activity first.
    func sessions() -> [AgentSession]
    /// Whether the session's agent still runs in a tab this app can show.
    func isLive(_ session: AgentSession) -> Bool
    /// Whether `sessions()` is the whole list. False while a daemon's list is not complete (its fold of the
    /// journal is behind): a session that is not in `sessions()` can still exist.
    var isComplete: Bool { get }
    /// True while the source's first answer is on its way and nothing says yet that it is slow (the app's own
    /// daemon starts). A list that is not complete then has no words on screen: at each healthy start they
    /// would show and go.
    var startsQuietly: Bool { get }
    /// The source can answer a read now (the app's own daemon is connected). A list that a read in the quiet
    /// start left not complete then has no words either: that read asked no daemon, and the next read does.
    var answersNow: Bool { get }
    /// Suspends before the read that follows `reads` reads of a list that is not complete (a clock sleep that
    /// backs off); it throws when the reader goes away.
    func waitForPending(afterReads reads: Int) async throws
}

package extension VaultSessionSource {
    /// A source whose list is always whole (fixed sessions).
    var isComplete: Bool { true }
    var startsQuietly: Bool { false }
    var answersNow: Bool { true }
    func waitForPending(afterReads reads: Int) async throws {}
}
