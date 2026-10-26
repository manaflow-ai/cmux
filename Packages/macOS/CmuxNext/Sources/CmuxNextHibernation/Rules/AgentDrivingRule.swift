// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// An agent called the page within `BrowserHibernation.agentGrace` (`cmux browser`, MCP, the REPL):
    /// its next call would wait on a restore (lead rule, as the agent's lease).
    package static let agentDriving = DiscardRule(.agentDriving, result: .protected, for: DiscardRule.leadRule,
                                                  kinds: DiscardRule.browserPages) { candidate, _ in
        candidate.isAgentDriving
    }
}
