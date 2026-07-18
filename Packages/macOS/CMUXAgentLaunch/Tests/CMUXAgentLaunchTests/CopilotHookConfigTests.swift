import CMUXAgentLaunch
import Foundation
import Testing

// Test-only compatibility keeps the assertions focused on JSON behavior while
// routing every call through an independently owned transformer instance.
extension CopilotHookConfig {
    static func installing(
        events: [Event],
        in existing: Data?,
        isOwnedCommand: (String) -> Bool
    ) throws -> Data {
        try CopilotHookConfig().installing(
            events: events,
            in: existing,
            isOwnedCommand: isOwnedCommand
        )
    }

    static func uninstalling(
        from existing: Data,
        isOwnedCommand: (String) -> Bool
    ) throws -> RemovalResult {
        try CopilotHookConfig().uninstalling(
            from: existing,
            isOwnedCommand: isOwnedCommand
        )
    }

    static func removingOwnedHooks(
        from existing: Data,
        isOwnedCommand: (String) -> Bool
    ) throws -> RemovalResult {
        try CopilotHookConfig().removingOwnedHooks(
            from: existing,
            isOwnedCommand: isOwnedCommand
        )
    }
}

@Suite("Copilot hook configuration")
struct CopilotHookConfigTests {
    private let owned: @Sendable (String) -> Bool = { command in
        command.contains("cmux hooks copilot") || command.contains("cmux hooks feed --source copilot")
    }

    @Test("Installs the native direct-entry schema idempotently")
    func installsNativeSchemaIdempotently() throws {
        let events = [
            CopilotHookConfig.Event(
                name: "sessionStart",
                command: "cmux hooks copilot session-start",
                timeoutSeconds: 5
            ),
            CopilotHookConfig.Event(
                name: "preToolUse",
                command: "cmux hooks feed --source copilot --event preToolUse",
                timeoutSeconds: 120
            ),
        ]
        let existing = Data(#"{"version":1,"hooks":{"sessionStart":[{"type":"command","command":"user-hook","timeoutSec":9}]}}"#.utf8)

        let installed = try CopilotHookConfig.installing(
            events: events,
            in: existing,
            isOwnedCommand: owned
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: installed) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        let hooks = try #require(object["hooks"] as? [String: Any])
        let starts = try #require(hooks["sessionStart"] as? [[String: Any]])
        #expect(starts.count == 2)
        #expect(starts[0]["command"] as? String == "user-hook")
        #expect(starts[1]["command"] as? String == "cmux hooks copilot session-start")
        #expect(starts[1]["timeoutSec"] as? Int == 5)
        #expect(starts[1]["hooks"] == nil)
        let tools = try #require(hooks["preToolUse"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["timeoutSec"] as? Int == 120)

        let reinstalled = try CopilotHookConfig.installing(
            events: events,
            in: installed,
            isOwnedCommand: owned
        )
        #expect(reinstalled == installed)
    }

    @Test("Migrates legacy nested cmux groups without changing user hooks")
    func removesLegacyNestedGroupsAndPreservesUsers() throws {
        let legacy = Data(#"""
        {
          "theme":"dark",
          "hooks":{
            "SessionStart":[
              {"matcher":"","hooks":[
                {"type":"command","command":"cmux hooks copilot session-start","timeout":5000},
                {"type":"command","command":"user-start"}
              ]}
            ],
            "PreToolUse":[
              {"hooks":[{"type":"command","command":"cmux hooks feed --source copilot --event PreToolUse"}]}
            ]
          }
        }
        """#.utf8)

        let removal = try CopilotHookConfig.removingOwnedHooks(
            from: legacy,
            isOwnedCommand: owned
        )
        #expect(removal.removedCount == 2)
        let data = try #require(removal.data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["theme"] as? String == "dark")
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect(hooks["PreToolUse"] == nil)
        let groups = try #require(hooks["SessionStart"] as? [[String: Any]])
        let nested = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(nested.count == 1)
        #expect(nested.first?["command"] as? String == "user-start")
    }

    @Test("Uninstall removes only owned direct entries")
    func uninstallPreservesUserEntries() throws {
        let installed = Data(#"""
        {
          "version":1,
          "hooks":{
            "sessionStart":[
              {"type":"command","command":"user-start","timeoutSec":9},
              {"type":"command","command":"cmux hooks copilot session-start","timeoutSec":5}
            ],
            "agentStop":[
              {"type":"command","command":"cmux hooks copilot stop","timeoutSec":5}
            ]
          }
        }
        """#.utf8)

        let removal = try CopilotHookConfig.uninstalling(
            from: installed,
            isOwnedCommand: owned
        )
        #expect(removal.removedCount == 2)
        let data = try #require(removal.data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect(hooks["agentStop"] == nil)
        let starts = try #require(hooks["sessionStart"] as? [[String: Any]])
        #expect(starts.count == 1)
        #expect(starts.first?["command"] as? String == "user-start")
    }

    @Test("Uninstall deletes a dedicated file that contains only cmux hooks")
    func uninstallDeletesOwnedOnlyFile() throws {
        let installed = Data(#"""
        {
          "version":1,
          "hooks":{"sessionStart":[{"type":"command","command":"cmux hooks copilot session-start"}]}
        }
        """#.utf8)

        let removal = try CopilotHookConfig.uninstalling(
            from: installed,
            isOwnedCommand: owned
        )
        #expect(removal.removedCount == 1)
        #expect(removal.data == nil)
    }

    @Test("Malformed or unsupported hook shapes fail closed")
    func malformedShapesFailClosed() {
        #expect(throws: CopilotHookConfig.ConfigError.invalidJSON) {
            _ = try CopilotHookConfig.installing(
                events: [],
                in: Data("{not-json".utf8),
                isOwnedCommand: owned
            )
        }
        #expect(throws: CopilotHookConfig.ConfigError.invalidHooks) {
            _ = try CopilotHookConfig.installing(
                events: [],
                in: Data(#"{"hooks":[]}"#.utf8),
                isOwnedCommand: owned
            )
        }
        #expect(throws: CopilotHookConfig.ConfigError.invalidEvent("sessionStart")) {
            _ = try CopilotHookConfig.installing(
                events: [],
                in: Data(#"{"hooks":{"sessionStart":{}}}"#.utf8),
                isOwnedCommand: owned
            )
        }
    }
}
