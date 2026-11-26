import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexLegacyRestoreCommandTests {
    private let session = "a1111111-2222-4333-8444-555555555555"

    @Test("Legacy account assignments become launch data, never login-shell evaluation")
    func literalResume() throws {
        let command = try #require(CodexLegacyRestoreCommand(
            command: "env CODEX_HOME='/saved account' /opt/bin/codex resume '\(session)' --model 'saved model'",
            sessionID: session
        ))
        #expect(command.environment == ["CODEX_HOME": "/saved account"])
        #expect(command.arguments == ["/opt/bin/codex", "resume", session, "--model", "saved model"])
    }

    @Test("A command with no inline account uses the persisted environment and cwd")
    func inheritedAccount() throws {
        let command = try #require(CodexLegacyRestoreCommand(command: "codex resume \(session)", sessionID: session))
        #expect(command.environment.isEmpty)
        #expect(CodexRestoreAccount().home(
            environment: ["CODEX_HOME": "account"], workingDirectory: "/saved", fallbackHome: "/unused"
        ) == "/saved/account")
    }

    @Test("An explicit remote provider remains remote after decoding")
    func remoteProvider() throws {
        let command = try #require(CodexLegacyRestoreCommand(
            command: "codex --remote=ws://remote resume \(session)", sessionID: session
        ))
        #expect(CodexRestoreAccount().usesRemoteProvider(arguments: command.arguments))
    }

    @Test(arguments: [
        "codex resume b2222222-3333-4444-8555-666666666666",
        "codex resume a1111111-2222-4333-8444-555555555555 --model $(pwd)",
        "launcher codex resume a1111111-2222-4333-8444-555555555555",
        "codex resume a1111111-2222-4333-8444-555555555555 --model gpt;true",
        "codex resume a1111111-2222-4333-8444-555555555555 --model gpt|cat",
        "codex --last",
        "env CODEX_HOME=$(pwd) codex resume a1111111-2222-4333-8444-555555555555"
    ])
    func ambiguousCommandIsRejected(command: String) {
        #expect(CodexLegacyRestoreCommand(command: command, sessionID: session) == nil)
    }
}
