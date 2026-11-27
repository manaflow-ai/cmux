public extension ComputerUseLiveSession {
    /// The session a Computer Use action acts on: the newest one started in one of `terminals` (a tab's host and
    /// public `term_…` ids, as `agent.terminal_id` names them), else the newest live one, as the File menu's actions do.
    ///
    /// - Parameters:
    ///   - live: The live sessions the CUA host lists.
    ///   - terminals: The terminals whose session goes first; empty for the newest.
    /// - Returns: The session, or nil when none is live.
    static func pick(_ live: [ComputerUseLiveSession], terminals: Set<String> = []) -> ComputerUseLiveSession? {
        let own = live.filter { $0.terminalID.map(terminals.contains) == true }
        return (own.isEmpty ? live : own).max(by: { $0.lastActionAt < $1.lastActionAt })
    }
}
