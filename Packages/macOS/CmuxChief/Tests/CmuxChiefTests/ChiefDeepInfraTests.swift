@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// DeepInfra models through Claude Code: the endpoint's environment, the credentials it
/// must never forward, and the failures a user reads without a key or with a bad one.
@Suite struct ChiefDeepInfraTests {
    private let conversation = ConversationID("c1")

    private func request() -> ChiefTurnRequest {
        ChiefTurnRequest(conversation: conversation, resumeSession: nil, userText: "hi", attachmentPaths: [],
                         replyContext: nil, systemPrompt: "", workingDirectory: FileManager.default.temporaryDirectory,
                         environment: [:])
    }

    private func collect(_ stream: AsyncThrowingStream<ChiefTurnEvent, any Error>) async throws -> [ChiefTurnEvent] {
        var events: [ChiefTurnEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func deepInfraRunsOnClaudeCodeAgainstItsAnthropicEndpoint() {
        let endpoint = ChiefModelEndpoint.deepInfra(token: "di-key")
        let environment = endpoint.environment(model: "deepseek-ai/DeepSeek-V4-Pro-0813")
        #expect(environment["ANTHROPIC_BASE_URL"] == "https://api.deepinfra.com/anthropic")
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == "di-key")
        // Claude Code's background and subagent calls stay on DeepInfra models.
        #expect(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "deepseek-ai/DeepSeek-V4-Flash-0731")
        for key in ["ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
                    "CLAUDE_CODE_SUBAGENT_MODEL"] {
            #expect(environment[key] == "deepseek-ai/DeepSeek-V4-Pro-0813", "\(key)")
        }
    }

    /// The app's own Anthropic credentials and provider switches must not reach a third-party
    /// endpoint, whatever environment the app was launched with.
    @Test func anthropicCredentialsNeverReachTheEndpoint() {
        let base = ["ANTHROPIC_API_KEY": "sk-ant-secret", "CLAUDE_CODE_OAUTH_TOKEN": "oauth-secret",
                    "ANTHROPIC_CUSTOM_HEADERS": "x-secret: 1", "CLAUDE_CODE_USE_BEDROCK": "1",
                    "CLAUDE_CODE_USE_VERTEX": "1", "ANTHROPIC_BASE_URL": "https://proxy.example", "PATH": "/usr/bin",
                    "CMUX_SURFACE_ID": "s1"]
        let endpoint = ChiefModelEndpoint.deepInfra(token: "di-key")
        let environment = ChiefExecutableResolver.environment(base: base, request: ["CMUX_CHIEF_TURN": "1"],
                                                              overrides: endpoint.environment(model: "m"),
                                                              removing: ChiefModelEndpoint.clearedKeys)
        for key in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CMUX_SURFACE_ID"] {
            #expect(environment[key] == nil, "\(key)")
        }
        #expect(environment["ANTHROPIC_BASE_URL"] == "https://api.deepinfra.com/anthropic")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["CMUX_CHIEF_TURN"] == "1")
    }

    @Test func theTokenNeverPrints() {
        let endpoint = ChiefModelEndpoint.deepInfra(token: "di-secret-key")
        #expect(!String(describing: endpoint).contains("di-secret-key"))
        #expect(!String(reflecting: endpoint).contains("di-secret-key"))
    }

    /// Without a key the turn fails before anything launches, pointing at Chief Settings.
    /// `/usr/bin/false` as the executable would make a launched turn fail differently.
    @Test func aTurnWithoutAKeyAsksForOne() async throws {
        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        let session = ClaudeConversation(configuration: .init(model: "m",
                                                              executableOverride: URL(fileURLWithPath: "/usr/bin/false"),
                                                              endpoint: .deepInfra(token: nil)))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        await session.start(request(), token: token, continuation: continuation, pending: pending)
        let events = try await collect(stream)
        #expect(events == [.failed(ChiefText.missingCredential("DeepInfra"))])
    }

    @Test func aRejectedKeyPointsAtChiefSettings() {
        let endpoint = ChiefModelEndpoint.deepInfra(token: "bad")
        for message in ["Invalid API key · Fix external API key",
                        #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid token"}}"#] {
            #expect(endpoint.failureMessage(message, model: "m") == ChiefText.invalidCredential("DeepInfra"))
        }
        #expect(endpoint.failureMessage("model_not_found", model: "m") == ChiefText.unknownModel("m", harness: "DeepInfra"))
        #expect(endpoint.failureMessage("Rate limit reached.", model: "m") == "Rate limit reached.")
    }

    @Test func theDeepInfraHarnessBuildsAClaudeCodeBrain() {
        #expect(ChiefHarness(lenient: "DeepInfra") == .deepInfra)
        #expect(ChiefHarness.deepInfra.displayName == "DeepInfra")
        #expect(ChiefHarness.deepInfra.defaultModel == "deepseek-ai/DeepSeek-V4-Pro-0813")
        #expect(ChiefHarness.deepInfra.makeBrain(model: nil, effort: nil, credential: "k") is ClaudeCodeBrain)
    }
}
