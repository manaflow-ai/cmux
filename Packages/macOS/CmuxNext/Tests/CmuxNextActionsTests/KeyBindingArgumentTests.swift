import AppKit
import CmuxNextActions
import Testing

/// Typed arguments on bindings (R59 `args`): an app or keybindings.json
/// entry's arguments are checked against its action's schema when the
/// layer loads. A bad entry is left out with an issue that names it; the
/// other entries load (a parse error disables only that entry, K4).
@MainActor
@Suite struct KeyBindingArgumentTests {
    static let ctrlK = Shortcut("k", modifiers: [.control])
    static let ctrlL = Shortcut("l", modifiers: [.control])
    static let colors = [ActionEnumCase(value: "sage", title: "Sage"), ActionEnumCase(value: "rust", title: "Rust")]

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "send", title: "Send Text", category: .terminal, arguments: [
                ActionArgument(name: "text", title: "Text", kind: .string),
                ActionArgument(name: "count", title: "Count", kind: .int(1...9), isRequired: false),
                ActionArgument(name: "paste", title: "Paste", kind: .bool, isRequired: false),
                ActionArgument(name: "color", title: "Color", kind: .enumeration(colors), isRequired: false),
                ActionArgument(name: "tab", title: "Tab", kind: .target(.tab), isRequired: false),
            ]),
            ActionDescriptor(id: "plain", title: "Plain", category: .terminal),
        ], aliases: ["legacy.send": "send"])
        for id: ActionID in ["send", "plain"] { registry.bind(id, invoke: { _ in }) }
        return registry
    }

    static func entry(_ command: ActionID, _ arguments: [String: ActionValue] = [:], keys: [Shortcut] = [ctrlK]) -> KeyBinding {
        KeyBinding(keys: keys, command: command, arguments: arguments, source: .user)
    }

    @Test func argumentsThatFitTheSchemaLoadNormalized() {
        let registry = Self.registry()
        let issues = KeyBindingLoader(registry).load(KeyBindingLayers(user: [
            Self.entry("legacy.send", ["text": .string("\u{1B}[A"), "count": .int(3), "paste": .string("yes"), "color": .string("sage"),
                                       "tab": .string("tab:t1")]),
        ]))
        #expect(issues.isEmpty)
        let loaded = registry.keyBindingLayers.user.first
        #expect(loaded?.command == "send", "an alias loads as its canonical id")
        #expect(loaded?.arguments["count"] == .int(3))
        #expect(loaded?.arguments["paste"] == .bool(true), "text that fits the kind is parsed")
        #expect(loaded?.arguments["tab"] == .target(ActionTargetRef(kind: .tab, id: "t1")))
        let winner = RegistryKeyBindings(registry).table.resolve([Self.ctrlK], in: KeyContext(bits: [])) { _ in true }.winner
        #expect(winner?.arguments["text"] == .string("\u{1B}[A"))
    }

    @Test func aBadEntryIsLeftOutWithAnIssueAndTheOthersLoad() {
        let registry = Self.registry()
        let issues = KeyBindingLoader(registry).load(KeyBindingLayers(
            app: [Self.entry("missing")],
            user: [
                Self.entry("send", ["text": .string("x"), "speed": .int(1)]),
                Self.entry("send", ["text": .int(4)]),
                Self.entry("send", ["text": .string("x"), "count": .int(12)]),
                Self.entry("send", ["text": .string("x"), "color": .string("blue")]),
                Self.entry("send", ["text": .string("x"), "tab": .target(ActionTargetRef(kind: .pane, id: "p1"))]),
                Self.entry("plain", keys: [Self.ctrlK, Self.ctrlL, Self.ctrlK, Self.ctrlL, Self.ctrlK]),
                Self.entry("plain", keys: [Shortcut("k", modifiers: [])]),
                Self.entry("plain", keys: []),
                Self.entry("plain", keys: [Self.ctrlL]),
            ]))
        #expect(issues == [
            KeyBindingIssue(source: .app, index: 0, kind: .unknownCommand("missing")),
            KeyBindingIssue(source: .user, index: 0, kind: .unknownArgument("speed")),
            KeyBindingIssue(source: .user, index: 1, kind: .invalidArgument("text")),
            KeyBindingIssue(source: .user, index: 2, kind: .invalidArgument("count")),
            KeyBindingIssue(source: .user, index: 3, kind: .invalidArgument("color")),
            KeyBindingIssue(source: .user, index: 4, kind: .invalidArgument("tab")),
            KeyBindingIssue(source: .user, index: 5, kind: .tooManyKeys),
            KeyBindingIssue(source: .user, index: 6, kind: .firstKeyNeedsCommandOrControl),
            KeyBindingIssue(source: .user, index: 7, kind: .noKeys),
        ])
        #expect(registry.keyBindingLayers.app.isEmpty)
        #expect(registry.keyBindingLayers.user.map(\.keys) == [[Self.ctrlL]], "only the valid entry loads")
    }

    /// A required argument may be left out: running the binding asks for it
    /// (the palette's argument collector), as from the palette.
    @Test func aMissingRequiredArgumentStillLoads() {
        let registry = Self.registry()
        #expect(KeyBindingLoader(registry).load(KeyBindingLayers(user: [Self.entry("send")])).isEmpty)
        #expect(registry.keyBindingLayers.user.count == 1)
    }

    /// Arguments reach the handler when the binding runs.
    @Test func argumentsReachTheHandler() {
        let registry = Self.registry()
        var received: [String: ActionValue] = [:]
        registry.bind("send", invoke: { received = $0.arguments })
        KeyBindingLoader(registry).load(KeyBindingLayers(user: [Self.entry("send", ["text": .string("hi"), "count": .int(2)])]))
        let winner = RegistryKeyBindings(registry).table.resolve([Self.ctrlK], in: KeyContext(bits: [])) { _ in true }.winner
        #expect(winner.map { RegistryKeyBindings(registry).run($0, keyContext: []) } == true)
        #expect(received == ["text": .string("hi"), "count": .int(2)])
    }
}
