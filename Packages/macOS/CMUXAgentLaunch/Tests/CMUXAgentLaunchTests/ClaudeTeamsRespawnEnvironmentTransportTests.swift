import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Claude Teams respawn environment transport")
struct ClaudeTeamsRespawnEnvironmentTransportTests {
    private let transport = ClaudeTeamsRespawnEnvironmentTransport()

    @Test("Round trip preserves PATH and replay-safe Claude configuration")
    func roundTripPreservesReplaySafeEnvironment() throws {
        let encoded = try #require(transport.encodedValue(from: [
            "PATH": "/opt/homebrew/bin:/Users/test/.local/share/mise/shims:/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": "/Users/test/Library/Application Support/Claude",
            "ANTHROPIC_MODEL": "claude-sonnet",
            "ANTHROPIC_API_KEY": "sk-ant-must-not-cross-respawn-transport",
            "CMUX_SURFACE_ID": "surface-must-not-cross-respawn-transport",
        ]))

        #expect(transport.decodedEnvironment(from: encoded) == [
            "PATH": "/opt/homebrew/bin:/Users/test/.local/share/mise/shims:/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": "/Users/test/Library/Application Support/Claude",
            "ANTHROPIC_MODEL": "claude-sonnet",
        ])
    }

    @Test("Decoder revalidates a forged transport value")
    func decoderRevalidatesTransport() throws {
        let forgedData = try JSONEncoder().encode([
            "PATH": "/custom/bin:/usr/bin",
            "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
            "ANTHROPIC_API_KEY": "secret",
            "CMUX_WORKSPACE_ID": "workspace-id",
        ])

        #expect(
            transport.decodedEnvironment(from: forgedData.base64EncodedString()) == [
                "PATH": "/custom/bin:/usr/bin",
                "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
            ]
        )
    }

    @Test("Malformed values fail closed")
    func malformedValuesFailClosed() {
        let invalidValues: [String?] = [
            nil,
            "",
            "not-base64",
            Data("[]".utf8).base64EncodedString(),
        ]
        for encodedValue in invalidValues {
            #expect(transport.decodedEnvironment(from: encodedValue).isEmpty)
        }
    }
}
