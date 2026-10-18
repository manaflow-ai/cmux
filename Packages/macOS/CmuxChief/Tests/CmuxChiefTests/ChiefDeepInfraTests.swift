@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// DeepInfra models through Claude Code: the `--settings` that point it at the endpoint,
/// the credentials it must never forward, where the key comes from, and the failures a
/// user reads without a key or with a bad one.
@Suite struct ChiefDeepInfraTests {
    private let conversation = ConversationID("c1")
    /// A variable no CI or developer environment sets, so the fallback is off unless a test sets it.
    private let unsetKey = "CMUX_CHIEF_TEST_PROVIDER_KEY_UNSET"

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

    private func keyFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chief-key-\(UUID().uuidString)")
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func settings(_ endpoint: ChiefModelEndpoint, model: String) throws -> [String: Any] {
        let data = Data(endpoint.settingsJSON(model: model).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Flag settings outrank the project settings in the Chief's working directory, so the
    /// endpoint, every model slot and blanked Anthropic credentials all travel in `--settings`.
    @Test func deepInfraSettingsPointClaudeCodeAtItsAnthropicEndpoint() throws {
        let endpoint = ChiefModelEndpoint.deepInfra(keyFile: URL(fileURLWithPath: "/tmp/key file"))
        let settings = try settings(endpoint, model: "deepseek-ai/DeepSeek-V4-Pro-0813")
        let environment = try #require(settings["env"] as? [String: String])
        #expect(environment["ANTHROPIC_BASE_URL"] == "https://api.deepinfra.com/anthropic")
        // Claude Code's background and subagent calls stay on DeepInfra models.
        #expect(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "deepseek-ai/DeepSeek-V4-Flash-0731")
        for key in ["ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
                    "CLAUDE_CODE_SUBAGENT_MODEL"] {
            #expect(environment[key] == "deepseek-ai/DeepSeek-V4-Pro-0813", "\(key)")
        }
        // Project settings' credentials and provider switches are overridden with nothing.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_TOKEN",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_UNIX_SOCKET"] {
            #expect(environment[key] == "", "\(key)")
        }
        // The key comes from the saved file, else the variable; the path is shell-quoted.
        #expect(settings["apiKeyHelper"] as? String == "cat '/tmp/key file' 2>/dev/null || printenv DEEPINFRA_API_KEY")
    }

    @Test func theKeyNeverTravelsInArgumentsOrTheEnvironment() throws {
        let file = try keyFile("di-secret-key")
        defer { try? FileManager.default.removeItem(at: file) }
        let configuration = ClaudeCodeBrain.Configuration(model: "m", endpoint: .deepInfra(keyFile: file))
        let arguments = ClaudeCodeBrain.arguments(configuration, session: .new("s"), systemPrompt: "")
        let index = try #require(arguments.firstIndex(of: "--settings"))
        #expect(arguments[index + 1] == ChiefModelEndpoint.deepInfra(keyFile: file).settingsJSON(model: "m"))
        #expect(!arguments.joined(separator: " ").contains("di-secret-key"))
        #expect(!String(describing: configuration).contains("di-secret-key"))
        // Without an endpoint, Claude Code keeps its own settings.
        #expect(!ClaudeCodeBrain.arguments(.init(model: "m"), session: .new("s"), systemPrompt: "").contains("--settings"))
    }

    /// The app's Anthropic routing and credentials must not reach a third-party endpoint,
    /// whatever environment the app was launched with.
    @Test func anthropicRoutingAndCredentialsAreStripped() {
        let base = ["ANTHROPIC_API_KEY": "sk-ant-secret", "CLAUDE_CODE_OAUTH_TOKEN": "oauth-secret",
                    "ANTHROPIC_CUSTOM_HEADERS": "x-secret: 1", "ANTHROPIC_UNIX_SOCKET": "/tmp/s",
                    "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_MANTLE": "1", "CLAUDE_CODE_GATEWAY_TOKEN": "g",
                    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR": "3", "ANTHROPIC_BASE_URL": "https://proxy.example",
                    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "4096", "PATH": "/usr/bin", "CMUX_SURFACE_ID": "s1"]
        let environment = ChiefExecutableResolver.environment(base: base, request: ["CMUX_CHIEF_TURN": "1"],
                                                              overrides: ["CMUX_CLAUDE_HOOKS_DISABLED": "1"],
                                                              removing: ChiefModelEndpoint.isClearedKey)
        #expect(environment == ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": "4096", "PATH": "/usr/bin",
                                "CMUX_CHIEF_TURN": "1", "CMUX_CLAUDE_HOOKS_DISABLED": "1"])
    }

    @Test func aKeyComesFromTheSavedFileOrTheEnvironment() throws {
        let saved = try keyFile("di-key\n")
        let empty = try keyFile("\n")
        let missing = try keyFile(nil)
        defer { for url in [saved, empty] { try? FileManager.default.removeItem(at: url) } }
        #expect(ChiefModelEndpoint.deepInfra(keyFile: saved, environmentKey: unsetKey).hasKey(environment: [:]))
        for file in [empty, missing] {
            let endpoint = ChiefModelEndpoint.deepInfra(keyFile: file, environmentKey: unsetKey)
            #expect(!endpoint.hasKey(environment: [:]))
            #expect(endpoint.hasKey(environment: [unsetKey: "env-key"]))
        }
        #expect(!ChiefModelEndpoint.deepInfra(keyFile: nil, environmentKey: unsetKey).hasKey(environment: [unsetKey: " "]))
    }

    /// Without a key the turn fails before anything launches, pointing at Chief Settings.
    /// `/usr/bin/false` as the executable would make a launched turn fail differently.
    @Test func aTurnWithoutAKeyAsksForOne() async throws {
        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        let endpoint = ChiefModelEndpoint.deepInfra(keyFile: try keyFile(nil), environmentKey: unsetKey)
        let session = ClaudeConversation(configuration: .init(model: "m",
                                                              executableOverride: URL(fileURLWithPath: "/usr/bin/false"),
                                                              endpoint: endpoint))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        await session.start(request(), token: token, continuation: continuation, pending: pending)
        let events = try await collect(stream)
        #expect(events == [.failed(ChiefText.missingCredential("DeepInfra"))])
    }

    @Test func aRejectedKeyPointsAtChiefSettings() {
        let endpoint = ChiefModelEndpoint.deepInfra(keyFile: nil)
        for message in ["Invalid API key · Fix external API key",
                        #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"User is not authorized to access this resource"}}"#] {
            #expect(endpoint.failureMessage(message, model: "m") == ChiefText.invalidCredential("DeepInfra"))
        }
        #expect(endpoint.failureMessage("model_not_found", model: "m") == ChiefText.unknownModel("m", harness: "DeepInfra"))
        #expect(endpoint.failureMessage("Rate limit reached.", model: "m") == "Rate limit reached.")
    }

    /// Claude Code retries a 401 up to ten times with growing delays; the parser reports
    /// the first one so the driver need not wait minutes for a key that will never work.
    @Test func aRetriedAuthenticationFailureIsReported() {
        var parser = ClaudeStreamParser()
        let retry = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":401,"error":"authentication_failed","session_id":"s"}"#
        #expect(parser.consume(Data(retry.utf8)) == [.rejectedCredential])
        let rateLimited = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":429,"error":"rate_limit","session_id":"s"}"#
        #expect(parser.consume(Data(rateLimited.utf8)).isEmpty)
        let forbidden = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":403,"error":"authentication_failed","session_id":"s"}"#
        #expect(parser.consume(Data(forbidden.utf8)).isEmpty)
    }

    /// A rejected key ends the turn at the first retry with the Chief Settings pointer,
    /// instead of leaving it spinning while `claude` backs off.
    @Test(.timeLimit(.minutes(1))) func aRejectedKeyEndsTheTurnWithoutWaitingForRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chief-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        echo '{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":401,"error":"authentication_failed","session_id":"s"}'
        exec sleep 600
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let key = try keyFile("di-bad-key")
        defer { try? FileManager.default.removeItem(at: key) }

        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        let session = ClaudeConversation(configuration: .init(model: "m", executableOverride: fake,
                                                              endpoint: .deepInfra(keyFile: key, environmentKey: unsetKey)))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        await session.start(request(), token: token, continuation: continuation, pending: pending)
        // The new session's id comes first; nothing else may precede the failure.
        let events = try await collect(stream).filter { if case .session = $0 { return false } else { return true } }
        #expect(events == [.failed(ChiefText.invalidCredential("DeepInfra"))])
    }

    @Test func theDeepInfraHarnessBuildsAClaudeCodeBrain() {
        #expect(ChiefHarness(lenient: "DeepInfra") == .deepInfra)
        #expect(ChiefHarness.deepInfra.displayName == "DeepInfra")
        #expect(ChiefHarness.deepInfra.needsCredential && !ChiefHarness.claude.needsCredential)
        #expect(ChiefHarness.deepInfra.defaultModel == "deepseek-ai/DeepSeek-V4-Pro-0813")
        #expect(ChiefHarness.deepInfra.makeBrain(model: nil, effort: nil, keyFile: nil) is ClaudeCodeBrain)
    }
}
