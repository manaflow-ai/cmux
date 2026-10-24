import CmuxNextAgentPane

extension AgentTabStore {
    /// The harness agent tab `key`'s chat runs: what acpmux reported for its session, else what its
    /// tab recorded. Nil for a chat that has not started one (NEW-WORK-INHERITS-CONTEXT: a new chat
    /// starts on the harness of the chat the person focused last).
    func harness(ofTab key: String) -> String? {
        let key = resolve(key)
        if let session = session(of: key), let reported = views[key]?.model.transport.sessions.harness(of: session) { return reported }
        return lookup(key)?.record.harness
    }
}
