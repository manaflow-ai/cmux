import CmuxNextSettings
import Testing

/// The agent chat's look (Settings > Appearance > Agent Chat, the chat's ··· menu Text & Width
/// popover; plans/cmux-next/chat-display-settings-DESIGN.md): each row has the page's default and
/// range and an agent may set it (looks only); the page gets the chat's values and the Markdown
/// viewer values it follows, and may write only the chat's own keys.
struct AgentPaneDisplaySettingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let key: String
        let fallback: JSONValue?
        let accepted: [JSONValue]
        let refused: [JSONValue]
        var testDescription: String { key }
    }

    static let rows: [Row] = [
        Row(key: "agentPane.display.width", fallback: .number(800), accepted: [.number(480), .number(1200), .number(4000)],
            refused: [.number(100), .number(5000), .string("wide")]),
        Row(key: "agentPane.display.fullWidth", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("yes")]),
        // The VS Code-style chat minimap: off unless turned on.
        Row(key: "agentPane.display.vscodeMinimap", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("on")]),
        Row(key: "agentPane.display.font.preset", fallback: .string("markdown"),
            accepted: [.string("system"), .string("serif"), .string("mono")], refused: [.string("comic")]),
        Row(key: "agentPane.display.font.size", fallback: .number(14), accepted: [.number(10), .number(28)],
            refused: [.number(4), .number(40)]),
        Row(key: "agentPane.display.font.lineHeight", fallback: .number(1.625), accepted: [.number(1.2), .number(2.4)],
            refused: [.number(0.5), .number(4)]),
        Row(key: "agentPane.display.code.family", fallback: nil, accepted: [.string("JetBrains Mono")], refused: [.number(3)]),
        Row(key: "agentPane.display.code.scale", fallback: nil, accepted: [.number(0.6), .number(1.25)],
            refused: [.number(0.2), .number(3)]),
        Row(key: "agentPane.display.inspector.placement", fallback: .string("overlay"), accepted: [.string("push")],
            refused: [.string("left"), .bool(true)]),
        Row(key: "agentPane.display.environment.placement", fallback: .string("left"),
            accepted: [.string("right"), .string("off")], refused: [.string("overlay"), .bool(true)]),
        Row(key: "markdown.code.family", fallback: nil, accepted: [.string("Menlo")], refused: [.bool(true)]),
    ]

    @Test(arguments: rows)
    func eachRowHasThePageDefaultAndRange(_ row: Row) throws {
        let path = row.key.split(separator: ".").map(String.init)
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        #expect(descriptor.defaultValue == row.fallback)
        for value in row.accepted { #expect(descriptor.accepts(value), "\(row.key) accepts \(value)") }
        for value in row.refused { #expect(!descriptor.accepts(value), "\(row.key) refuses \(value)") }
        #expect(SettingsSchema.agentSettableKeys.contains(row.key))
    }

    @Test func thePageGetsTheChatKeysAndTheFollowedMarkdownKeysOnly() {
        let root: JSONValue = .object([
            "agentPane": .object(["display": .object([
                "font": .object(["size": .number(16), "lineHeight": .number(9)]),
                "width": .number(1200),
                "environment": .object(["placement": .string("right")]),
            ])]),
            "markdown": .object([
                "font": .object(["preset": .string("serif"), "size": .number(20)]),
                "code": .object(["family": .string("JetBrains Mono"), "scale": .number(0.9)]),
                "layout": .object(["width": .number(60)]),
            ]),
        ])
        let display = AgentPaneDisplaySetting(fileRoot: root)
        #expect(display.values == [
            "agentPane.display.font.size": .number(16),
            "agentPane.display.environment.placement": .string("right"),
            "agentPane.display.width": .number(1200),
            "markdown.font.preset": .string("serif"),
            "markdown.code.family": .string("JetBrains Mono"),
            "markdown.code.scale": .number(0.9),
        ])
        #expect(AgentPaneDisplaySetting(fileRoot: .object([:])) == .fallback)
    }

    @Test func thePageFollowsMinimalMode() {
        let on: JSONValue = .object(["sidebar": .object(["minimal": .bool(true), "density": .string("compact")])])
        #expect(AgentPaneDisplaySetting(fileRoot: on).values == ["sidebar.minimal": .bool(true)])
        let bad: JSONValue = .object(["sidebar": .object(["minimal": .string("yes")])])
        #expect(AgentPaneDisplaySetting(fileRoot: bad) == .fallback)
    }

    @Test(arguments: [
        "agentPane.display.width", "agentPane.display.code.family", "agentPane.display.font.size",
        "agentPane.display.inspector.placement", "agentPane.display.environment.placement",
    ])
    func thePageMayWriteTheChatKeys(_ key: String) {
        #expect(AgentPaneDisplaySetting.writablePath(key) == key.split(separator: ".").map(String.init))
    }

    @Test(arguments: ["markdown.font.size", "terminal.fontFamily", "agentPane.showDictation", "agentPane.display", "sidebar.minimal", ""])
    func thePageMayWriteNoOtherKey(_ key: String) {
        #expect(AgentPaneDisplaySetting.writablePath(key) == nil)
    }
}
