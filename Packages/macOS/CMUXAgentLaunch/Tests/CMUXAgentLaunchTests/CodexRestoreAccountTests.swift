import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexRestoreAccountTests {
    @Test("Codex home uses literal paths and the actual launch cwd")
    func exactAccount() {
        let resolver = CodexRestoreAccount()
        #expect(resolver.home(
            environment: ["CODEX_HOME": "~/literal ", "HOME": "/wrong", "PWD": "/wrong"],
            workingDirectory: "/project", fallbackHome: "/fallback"
        ) == "/project/~/literal ")
        #expect(resolver.home(
            environment: ["HOME": "/user"], workingDirectory: "/project", fallbackHome: "/fallback"
        ) == "/user/.codex")
    }

    @Test("Prompt and configuration values cannot disable local lock inspection")
    func remoteArguments() {
        let resolver = CodexRestoreAccount()
        #expect(resolver.usesRemoteProvider(arguments: ["codex", "--remote=ws://remote", "resume", "id"]))
        #expect(!resolver.usesRemoteProvider(arguments: ["codex", "-c", "--remote=value", "resume", "id"]))
        #expect(!resolver.usesRemoteProvider(arguments: ["codex", "resume", "id", "--", "--remote=value"]))
    }
}
