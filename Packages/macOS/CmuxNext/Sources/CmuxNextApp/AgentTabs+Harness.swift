import CmuxNextAgentPane

extension AgentTabStore {
    /// The harness agent tab `key`'s chat runs: what acpmux reported for its session, else what its
    /// tab recorded. Nil for a chat that has not started one (NEW-WORK-INHERITS-CONTEXT: a new chat
    /// starts on the harness of the chat the person focused last).
    func harness(ofTab key: String, machine: String? = nil) -> String? {
        let key = resolvedKey(tabKey(key, machine: machine))
        if let session = session(of: key.key, machine: key.machine), let reported = views[key]?.model.transport.sessions.harness(of: session) { return reported }
        return record(for: key)?.record.harness
    }
}
