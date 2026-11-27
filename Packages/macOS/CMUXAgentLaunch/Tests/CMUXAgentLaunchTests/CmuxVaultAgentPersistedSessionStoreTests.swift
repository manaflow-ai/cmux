import CMUXAgentLaunch
import Testing

@Suite("CmuxVaultAgentPersistedSessionStore")
struct CmuxVaultAgentPersistedSessionStoreTests {
    @Test("Parses every Hermes resume spelling", arguments: [
        ["--resume", "durable-session"],
        ["--resume=durable-session"],
        ["-r", "durable-session"],
        ["-r=durable-session"],
        ["-rdurable-session"],
    ])
    func parsesHermesResumeSpellings(arguments: [String]) {
        #expect(
            CmuxVaultAgentPersistedSessionStore.hermesStateDB
                .explicitSessionID(arguments: arguments) == "durable-session"
        )
    }
}
