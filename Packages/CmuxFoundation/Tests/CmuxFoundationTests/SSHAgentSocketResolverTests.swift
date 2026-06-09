import Testing
@testable import CmuxFoundation

struct SSHAgentSocketResolverTests {
    @Test func normalizedAgentSocketPathExpandsTildeAgainstResolverEnvironmentHome() {
        let resolver = SSHAgentSocketResolver(environment: [
            "HOME": "/tmp/cmux-test-home",
        ])

        #expect(resolver.normalizedAgentSocketPath("~/.ssh/agent.sock") == "/tmp/cmux-test-home/.ssh/agent.sock")
        #expect(resolver.normalizedAgentSocketPath("~") == "/tmp/cmux-test-home")
    }
}
