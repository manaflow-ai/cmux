import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `agent.chat.drive` drives a chat page in the person's own Release or Nightly app, so it is
/// registered outside every `#if` (a `debug.` method or a DEBUG-only registration never reaches that
/// build), and it takes only the params it names, each in its range: a test id is a name, never a selector.
@Suite struct AgentChatDriveControlTests {
    typealias Params = AgentChatDriveControl.Params

    /// AppControl registers it with `agent.chat.perf` (``AgentChatPerfControl/controlMethods()``), whose
    /// own test checks that registration is outside every `#if`.
    @Test func theMethodIsRegisteredInEveryBuild() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CmuxNextApp")
        let text = try String(contentsOf: sources.appendingPathComponent("Control/AppControl.swift"), encoding: .utf8)
        #expect(text.contains("}.controlMethods(sources:"))
        let names = AgentChatPerfControl { _ in .missing }.controlMethods().map(\.name)
        #expect(names == [AgentChatPerfControl.method, AgentChatDriveControl.method])
        #expect(!AgentChatDriveControl.method.hasPrefix("debug."))
    }

    @Test func theDefaults() throws {
        let params = try Params(["tab": "0123ABCD-0123-4567-89AB-0123456789AB"])
        #expect(params.tab == "tab_0123abcd0123456789ab0123456789ab")
        #expect(params.seconds == AgentChatDriveControl.defaultSeconds)
        #expect(params.holdMilliseconds == 500)
        #expect(params.allowBusy == false)
        #expect(params.target == nil && params.wheel == nil && params.type == nil)
    }

    @Test func aFullRun() throws {
        let params = try Params([
            "tab": "tab_x", "target": ["test_id": "tool-card_2"], "seconds": 30, "hold_ms": 0, "allow_busy": true,
            "wheel": ["ticks": 200, "delta": -2000, "tick_ms": 8], "type": ["text": "hi", "allow_draft": true],
        ])
        #expect(params.target == .testID("tool-card_2"))
        #expect(params.wheel?.ticks == 200 && params.wheel?.delta == -2000 && params.wheel?.tickMilliseconds == 8)
        #expect(params.type?.text == "hi" && params.type?.allowDraft == true)
        #expect(try Params(["tab": "t", "target": ["sent_image": 1]]).target == .sentImage(1))
        #expect(try Params(["tab": "t", "target": ["tool_screenshot": 3]]).target == .toolScreenshot(3))
        #expect(try Params(["tab": "t", "wheel": ["ticks": 0]]).wheel?.tickMilliseconds == 16)
    }

    @Test(arguments: [
        [:],
        ["tab": ""],
        ["tab": "t", "selector": "#box"],
        ["tab": "t", "seconds": 0], ["tab": "t", "seconds": 31], ["tab": "t", "seconds": 2.5], ["tab": "t", "seconds": "5"],
        ["tab": "t", "hold_ms": -1], ["tab": "t", "hold_ms": 10_001],
        ["tab": "t", "allow_busy": 1],
        ["tab": "t", "target": "box"], ["tab": "t", "target": [:]],
        ["tab": "t", "target": ["test_id": "a", "sent_image": 1]],
        ["tab": "t", "target": ["test_id": ""]], ["tab": "t", "target": ["test_id": "[data-x]"]],
        ["tab": "t", "target": ["test_id": "a b"]], ["tab": "t", "target": ["test_id": .string(String(repeating: "a", count: 81))]],
        ["tab": "t", "target": ["sent_image": 0]], ["tab": "t", "target": ["tool_screenshot": 1.5]],
        ["tab": "t", "target": ["selector": "#box"]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 201, "delta": 10]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 1, "delta": 0]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 1, "delta": 2001]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 1, "delta": 10, "tick_ms": 7]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 1, "delta": 10, "tick_ms": 201]],
        ["tab": "t", "target": ["test_id": "a"], "wheel": ["ticks": 1, "delta": 10, "x": 1]],
        ["tab": "t", "wheel": ["ticks": 1, "delta": 10]],
        ["tab": "t", "type": ["text": ""]], ["tab": "t", "type": ["text": .string(String(repeating: "a", count: 501))]],
        ["tab": "t", "type": ["text": "a", "allow_draft": "yes"]], ["tab": "t", "type": ["text": "a", "script": "x"]],
        // 200 ticks of 200 ms is 40 s: longer than the 30 s bound.
        ["tab": "t", "seconds": 30, "target": ["test_id": "a"], "wheel": ["ticks": 200, "delta": 10, "tick_ms": 200]],
        ["tab": "t", "seconds": 1, "hold_ms": 1001],
    ] as [[String: JSONValue]])
    func anythingElseIsRefused(_ raw: [String: JSONValue]) {
        #expect(throws: ControlError.self) { try Params(raw) }
    }

    /// The page types the text as a person's keys: nothing a key can't type, nothing that would start a
    /// composer command in an empty draft (the host can't see the draft, so a leading `!` is always refused).
    /// The `--type` cases both sides check: the CLI refuses what the app answers `invalid_params` to
    /// (cmux-tui `app_chat_drive_type_text_matches_the_shared_table` reads the same file).
    private struct TypeTable: Decodable {
        struct Case: Decodable {
            let text: String
            let repeatCount: Int?
            let why: String?
            enum CodingKeys: String, CodingKey { case text, repeatCount = "repeat", why }
            var full: String { String(repeating: text, count: repeatCount ?? 1) }
        }
        let maxGraphemes: Int
        let maxUTF16: Int
        let maxImageIndex: Int
        let typable: [Case]
        let refused: [Case]
        enum CodingKeys: String, CodingKey { case maxGraphemes = "max_graphemes", maxUTF16 = "max_utf16", maxImageIndex = "max_image_index", typable, refused }

        static func load() throws -> TypeTable {
            var root = URL(fileURLWithPath: #filePath)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
                let parent = root.deletingLastPathComponent()
                try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
                root = parent
            }
            let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/fixtures/chat-drive-type-text.json"))
            return try JSONDecoder().decode(TypeTable.self, from: data)
        }
    }

    @Test func typedTextIsPlainKeysOnly() throws {
        let table = try TypeTable.load()
        #expect(table.maxGraphemes == 500 && table.maxUTF16 == 2000)
        #expect(table.maxImageIndex == Params.maxImageIndex, "the CLI and the app bound image positions alike")
        for key in ["sent_image", "tool_screenshot"] {
            #expect(throws: Never.self) { try Params(["tab": "t", "target": [key: .number(Double(Params.maxImageIndex))]]) }
            #expect(throws: ControlError.self) { try Params(["tab": "t", "target": [key: .number(Double(Params.maxImageIndex + 1))]]) }
        }
        for good in table.typable.map(\.full) {
            #expect(Params.isTypable(good), "\(good)")
            #expect(try Params(["tab": "t", "type": ["text": .string(good)]]).type?.text == good)
        }
        for bad in table.refused {
            for draft in [false, true] {
                #expect(throws: ControlError.self, "\(bad.full.debugDescription) (\(bad.why ?? ""))") {
                    try Params(["tab": "t", "type": ["text": .string(bad.full), "allow_draft": .bool(draft)]])
                }
            }
        }
    }

    @Test func aTestIDIsANameNeverASelector() {
        #expect(Params.isTestID("tool-card_2"))
        #expect(Params.isTestID(String(repeating: "Z", count: 80)))
        for bad in ["", "#box", "a.b", "a b", "é", "a\"]", String(repeating: "a", count: 81)] { #expect(!Params.isTestID(bad), "\(bad)") }
    }
}
