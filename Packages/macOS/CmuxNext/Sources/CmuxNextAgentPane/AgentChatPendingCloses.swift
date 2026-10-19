/// Defers a chat tab's close until its provisional surface has a daemon tab.
@MainActor
package final class AgentChatPendingCloses {
    private var closes: [String: @MainActor (String) -> Void] = [:]

    package init() {}

    package func add(_ key: String, provisional: Bool, aliased: Bool, registered: Bool,
                     close: @escaping @MainActor (String) -> Void) -> Bool {
        guard provisional, !aliased, registered else { return false }
        closes[key] = close
        return true
    }

    /// Closes a completed creation first, otherwise binds the session its page already started.
    package func created(_ key: String, as created: String, session: String?, remote: Bool, send: (String, String) -> Void) {
        if let close = closes.removeValue(forKey: key) {
            close(created)
        } else if let session, !remote {
            send(session, created)
        }
    }

    package func release(_ key: String) { closes[key] = nil }
}
