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
        Row(key: "agentPane.display.harnessPlacement", fallback: .string("symbols"),
            accepted: [.string("symbols"), .string("left"), .string("top"), .string("compact")],
            refused: [.string("right"), .bool(true)]),
        Row(key: "agentPane.display.width", fallback: .number(800), accepted: [.number(480), .number(1200), .number(4000)],
            refused: [.number(100), .number(5000), .string("wide")]),
        Row(key: "agentPane.display.fullWidth", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("yes")]),
        // The VS Code-style chat minimap: off unless turned on.
        Row(key: "agentPane.display.vscodeMinimap", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("on")]),
        // The running turn's task list pinned in the chat: off, the composer's hat shows it.
        Row(key: "agentPane.display.pinnedPlan", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("on")]),
        // The hat over the composer tucked away to its pull tab: off, it shows.
        Row(key: "agentPane.display.trayTucked", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("on")]),
        // Where the hat's tuck handle sits along the composer's top edge: the middle unless set.
        Row(key: "agentPane.display.trayHandle", fallback: .string("middle"), accepted: [.string("left"), .string("right")],
            refused: [.string("top"), .bool(true)]),
        Row(key: "agentPane.display.font.preset", fallback: .string("markdown"),
            accepted: [.string("system"), .string("serif"), .string("mono")], refused: [.string("comic")]),
        Row(key: "agentPane.display.font.size", fallback: .number(14), accepted: [.number(10), .number(28)],
            refused: [.number(4), .number(40)]),
        Row(key: "agentPane.display.font.lineHeight", fallback: .number(1.625), accepted: [.number(1.2), .number(2.4)],
            refused: [.number(0.5), .number(4)]),
        Row(key: "agentPane.display.code.family", fallback: nil, accepted: [.string("JetBrains Mono")], refused: [.number(3)]),
        Row(key: "agentPane.display.code.scale", fallback: nil, accepted: [.number(0.6), .number(1.25)],
            refused: [.number(0.2), .number(3)]),
        Row(key: "agentPane.display.sessionInfo.placement", fallback: .string("overlay"), accepted: [.string("push")],
            refused: [.string("left"), .bool(true)]),
        Row(key: "agentPane.display.environment.placement", fallback: .string("left"),
            accepted: [.string("right"), .string("off")], refused: [.string("overlay"), .bool(true)]),
        Row(key: "agentPane.display.minimap", fallback: .string("compact"), accepted: [.string("off"), .string("full")],
            refused: [.bool(true), .string("left")]),
        // The transcript's view (Normal, Thinking, Verbose) of a chat without its own.
        Row(key: "agentPane.display.transcriptView", fallback: .string("normal"),
            accepted: [.string("thinking"), .string("verbose")], refused: [.string("loud"), .bool(true)]),
        Row(key: "agentPane.display.presentation", fallback: .string("transcript"),
            accepted: [.string("messages")], refused: [.string("bubbles"), .bool(true)]),
        Row(key: "agentPane.display.rail.side", fallback: .string("left"), accepted: [.string("right")],
            refused: [.string("top"), .bool(true)]),
        Row(key: "markdown.code.family", fallback: nil, accepted: [.string("Menlo")], refused: [.bool(true)]),
        // How the running tray names background commands: preset names and rules of one's own.
        Row(key: "agentPane.display.commandLabels", fallback: .array([]),
            accepted: [.array([.string("cmux-fleet"), .object(["program": .string("deploy"), "label": .string("Deploying")])]),
                       .array([.object(["match": .string("^x"), "label": .string("X"), "icon": .string("cloud")])])],
            refused: [.string("cmux-fleet"), .array([.object(["label": .string("x")])]), .array([.string(" ")])]),
    ]

    @Test func thePageGetsAValidCommandLabelsListAndNotAnInvalidOne() {
        let key = "agentPane.display.commandLabels"
        let valid: JSONValue = ["agentPane": ["display": ["commandLabels": .array([.string("cmux-fleet")])]]]
        #expect(AgentPaneDisplaySetting(fileRoot: valid).values[key] == .array([.string("cmux-fleet")]))
        let invalid: JSONValue = ["agentPane": ["display": ["commandLabels": .array([.number(1)])]]]
        #expect(AgentPaneDisplaySetting(fileRoot: invalid).values[key] == nil)
    }

    @Test(arguments: rows)
    func eachRowHasThePageDefaultAndRange(_ row: Row) throws {
        let path = row.key.split(separator: ".").map(String.init)
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        #expect(descriptor.defaultValue == row.fallback)
        for value in row.accepted { #expect(descriptor.accepts(value), "\(row.key) accepts \(value)") }
        for value in row.refused { #expect(!descriptor.accepts(value), "\(row.key) refuses \(value)") }
        #expect(SettingsSchema.agentSettableKeys.contains(row.key))
    }

    @Test func harnessPlacementPreservesAbsenceAndForwardsManagedValueSeparately() {
        let key = "agentPane.display.harnessPlacement"
        #expect(AgentPaneDisplaySetting(fileRoot: .object([:])).values[key] == nil)
        let root: JSONValue = ["agentPane": ["display": ["harnessPlacement": "symbols"]]]
        let value = AgentPaneDisplaySetting(fileRoot: root, managedHarnessPlacement: .string("left"))
        #expect(value.values[key] == .string("symbols"))
        #expect(value.values[key + ".managed"] == .string("left"))
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

    /// `agentPane.display.minimap` was an on/off toggle before it was the Rail / Full Map / Off choice.
    /// A settings file the toggle wrote keeps its meaning on the way to the page: `true` (the full
    /// map) arrives as `"full"`, and `false` (the experiment decides) arrives as no value at all,
    /// as it did before. Without this the choice row refused `true`, the page got nothing, and a
    /// person who had turned the map on lost it.
    @Test func theOldMinimapToggleKeepsItsMeaning() {
        func page(_ value: JSONValue) -> JSONValue? {
            let root: JSONValue = .object(["agentPane": .object(["display": .object(["minimap": value])])])
            return AgentPaneDisplaySetting(fileRoot: root).values["agentPane.display.minimap"]
        }
        #expect(page(.bool(true)) == .string("full"))
        #expect(page(.bool(false)) == nil)
        #expect(page(.string("compact")) == .string("compact"))
        #expect(page(.string("off")) == .string("off"))
        #expect(page(.string("yes")) == nil)
    }

    /// The Session Info row was `agentPane.display.inspector.placement`: a file that still holds the
    /// old key keeps its Push or Overlay on the page, and the new key wins when both are set.
    @Test func theOldSessionInfoKeyStillApplies() {
        let key = "agentPane.display.sessionInfo.placement"
        func page(_ display: [String: JSONValue]) -> JSONValue? {
            AgentPaneDisplaySetting(fileRoot: .object(["agentPane": .object(["display": .object(display)])])).values[key]
        }
        let old: JSONValue = .object(["placement": .string("push")])
        #expect(page(["inspector": old]) == .string("push"))
        #expect(page(["inspector": old, "sessionInfo": .object(["placement": .string("overlay")])]) == .string("overlay"))
        #expect(page(["inspector": .object(["placement": .string("left")])]) == nil)
    }

    @Test(arguments: [true, false])
    func theOldMinimapToggleAgreesAcrossSettingsAndTheChat(_ on: Bool) throws {
        let path = ["agentPane", "display", "minimap"]
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        let root: JSONValue = .object(["agentPane": .object(["display": .object(["minimap": .bool(on)])])])
        let expected: JSONValue = .string(on ? "full" : "compact")
        // Settings and the palette read this descriptor value.
        #expect(descriptor.effectiveValue(in: root) == expected)
        let chat = AgentPaneDisplaySetting(fileRoot: root).values[descriptor.id] ?? descriptor.defaultValue
        #expect(chat == expected)
    }

    @Test func thePageFollowsMinimalMode() {
        let on: JSONValue = .object(["sidebar": .object(["minimal": .bool(true), "density": .string("compact")])])
        #expect(AgentPaneDisplaySetting(fileRoot: on).values == ["sidebar.minimal": .bool(true)])
        let bad: JSONValue = .object(["sidebar": .object(["minimal": .string("yes")])])
        #expect(AgentPaneDisplaySetting(fileRoot: bad) == .fallback)
    }

    @Test(arguments: [
        "agentPane.display.width", "agentPane.display.code.family", "agentPane.display.font.size",
        "agentPane.display.sessionInfo.placement", "agentPane.display.environment.placement",
        "agentPane.display.minimap", "agentPane.display.transcriptView", "agentPane.display.presentation", "agentPane.display.rail.side",
    ])
    func thePageMayWriteTheChatKeys(_ key: String) {
        #expect(AgentPaneDisplaySetting.writablePath(key) == key.split(separator: ".").map(String.init))
    }

    @Test(arguments: ["markdown.font.size", "terminal.fontFamily", "agentPane.showDictation", "agentPane.display", "sidebar.minimal", ""])
    func thePageMayWriteNoOtherKey(_ key: String) {
        #expect(AgentPaneDisplaySetting.writablePath(key) == nil)
    }
}
