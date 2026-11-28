import CMUXAgentLaunch
import Testing

@Suite("HermesAgentSessionResolver")
struct HermesAgentSessionResolverTests {
    @Test("Uses HERMES_HOME when set")
    func usesHermesHomeWhenSet() {
        let env = ["HOME": "/Users/example", "HERMES_HOME": "/tmp/hermes profile"]

        #expect(HermesAgentSessionResolver.hermesHome(env: env) == "/tmp/hermes profile")
        #expect(HermesAgentSessionResolver.configPath(env: env) == "/tmp/hermes profile/config.yaml")
        #expect(HermesAgentSessionResolver.stateDBPath(env: env) == "/tmp/hermes profile/state.db")
        #expect(HermesAgentSessionResolver.allowlistPath(env: env) == "/tmp/hermes profile/shell-hooks-allowlist.json")
    }

    @Test("Falls back to HOME dot hermes")
    func fallsBackToHomeDotHermes() {
        let env = ["HOME": "/Users/example"]

        #expect(HermesAgentSessionResolver.hermesHome(env: env) == "/Users/example/.hermes")
        #expect(HermesAgentSessionResolver.configPath(env: env) == "/Users/example/.hermes/config.yaml")
    }

    @Test("Expands tilde with supplied HOME")
    func expandsTildeWithSuppliedHome() {
        let env = ["HOME": "/Users/example", "HERMES_HOME": "~/profiles/coder"]

        #expect(HermesAgentSessionResolver.hermesHome(env: env) == "/Users/example/profiles/coder")
    }
}
