import os

/// Records each time an agent pane says its tab's chat isn't available (`chat.missing`), with the
/// chat's session id and why, in the unified log (subsystem `com.cmuxterm.app.next`, category
/// `agentPane`), so the views can be counted:
///
/// ```sh
/// log show --last 1d --predicate 'subsystem == "com.cmuxterm.app.next" AND eventMessage BEGINSWITH "chat.missing"'
/// ```
nonisolated struct AgentPaneMissingChatLog: Sendable {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agentPane")

    /// Logs one view of the missing-chat line.
    ///
    /// - Parameters:
    ///   - session: the session the page looked for.
    ///   - reason: the page's reason (`notListedAtOpen`, `leftListWhileShown`).
    ///   - tabSession: the session the tab records, when it differs from `session`.
    ///   - remote: whether the chat runs on another machine.
    func record(session: String, reason: String, tabSession: String?, remote: Bool) {
        let recorded = tabSession ?? "none"
        logger.error("chat.missing session=\(session, privacy: .public) reason=\(reason, privacy: .public) tabSession=\(recorded, privacy: .public) remote=\(remote, privacy: .public)")
    }
}
