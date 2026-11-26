import CmuxNextActions
@testable import CmuxNextApps
import Testing

/// An extension's catalog `keyboard` shortcuts run its command (`app.command.run`) from the
/// binding table's app layer: `examples/extensions/reader-mode` asks for Cmd-Shift-R while a
/// browser tab has the keyboard, which cmux ignored until now (its README had to give a
/// keybindings.json line instead). A hidden or disabled app contributes none, and the user's
/// keybindings.json still wins over and removes them.
@MainActor @Suite struct AppKeyBindingsTests {
    static let cmdShiftR = Shortcut("r", modifiers: [.command, .shift])
    nonisolated static let browser: [String: KeyContextValue] = ["browserFocused": .bool(true)]

    static func record(hidden: Bool = false, enabled: Bool = true, keys: [AppJSON]) -> AppRecord? {
        AppRecord(json: [
            "id": "local/reader-mode", "installed": true, "hidden": .bool(hidden), "enabled": .bool(enabled),
            "manifest": ["manifestVersion": 2, "id": "local/reader-mode", "name": "Reader Mode", "version": "1.0.0"],
            "commands": [["op": "local.reader_mode.toggle", "title": "Reader Mode: Toggle", "keys": .array(keys)]],
        ])
    }

    static func bindings(_ record: AppRecord?) -> [KeyBinding] {
        AppKeyBindings.bindings([record].compactMap { $0 })
    }

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return registry
    }

    static func winner(_ registry: ActionRegistry, _ context: [String: KeyContextValue]) -> KeyBinding? {
        RegistryKeyBindings(registry).table.resolve([cmdShiftR], in: KeyContext(context), isRunnable: { _ in true }).winner
    }

    @Test func catalogKeysBecomeAppCommandRunEntries() throws {
        let bindings = Self.bindings(Self.record(keys: [["key": "cmd+shift+r", "when": "browserFocused"]]))
        let binding = try #require(bindings.first)
        #expect(bindings.count == 1)
        #expect(binding.keys == [Self.cmdShiftR])
        #expect(binding.command == "app.command.run")
        #expect(binding.arguments == ["app": .string("local/reader-mode"), "command": .string("local.reader_mode.toggle")])
        #expect(binding.when?.text == "browserFocused")
        #expect(binding.source == .app)
    }

    @Test func hiddenOrDisabledAppsContributeNoKeys() {
        let keys: [AppJSON] = [["key": "cmd+shift+r"]]
        #expect(Self.bindings(Self.record(hidden: true, keys: keys)).isEmpty)
        #expect(Self.bindings(Self.record(enabled: false, keys: keys)).isEmpty)
    }

    @Test func unparseableKeysAndWhenClausesAreSkipped() {
        let keys: [AppJSON] = [["key": "hyper+r"], ["key": "cmd+shift+r", "when": "browserFocused &&"], ["key": "cmd+k"]]
        #expect(Self.bindings(Self.record(keys: keys)).map(\.keys) == [[Shortcut("k", modifiers: [.command])]])
    }

    /// Loaded into the registry, the key runs the app's command in a browser tab (above cmux's
    /// default Hard Reload there, the app layer's documented precedence) and nowhere else, and a
    /// user removal takes it out again.
    @Test func loadedKeyResolvesInItsContextAndUserRemovalWins() throws {
        let registry = Self.registry()
        let bindings = Self.bindings(Self.record(keys: [["key": "cmd+shift+r", "when": "browserFocused"]]))
        #expect(KeyBindingLoader(registry).loadApp(bindings).isEmpty)
        #expect(Self.winner(registry, Self.browser)?.command == "app.command.run")
        #expect(Self.winner(registry, [:])?.command != "app.command.run")
        KeyBindingLoader(registry).load(KeyBindingLayers(app: registry.keyBindingLayers.app,
                                                         removals: [KeyBindingRemoval(command: "app.command.run")]))
        #expect(Self.winner(registry, Self.browser)?.command != "app.command.run")
    }

    /// The wire record round-trips the keys (the fake transport answers with `json`).
    @Test func recordJSONKeepsKeys() throws {
        let record = try #require(AppRecord(json: [
            "id": "local/reader-mode", "installed": true,
            "manifest": ["manifestVersion": 2, "id": "local/reader-mode", "name": "Reader Mode", "version": "1.0.0"],
            "commands": [["op": "local.reader_mode.toggle", "title": "Reader Mode: Toggle",
                          "keys": [["key": "cmd+shift+r", "when": "browserFocused"]],
                          "page_keys": ["f", "shift+f", "g"],
                          "page_key_when": ["f": "browserFocused", "shift+f": "browserFocused && !readOnly",
                                             "g": "browserFocused || paneFocused:editor"]]],
        ]))
        let again = try #require(AppRecord(json: record.json))
        #expect(again.commands.first?.keys == [AppRecord.Command.Key(key: "cmd+shift+r", when: "browserFocused")])
        #expect(again.commands.first?.pageKeys == ["f", "shift+f", "g"])
        #expect(again.commands.first?.answers(pageKey: "f", shift: false) == true)
        #expect(again.commands.first?.answers(pageKey: "f", shift: true) == true)
        #expect(again.commands.first?.answers(pageKey: "f", shift: true,
                                              context: KeyContext(["browserFocused": .bool(true), "readOnly": .bool(true)])) == false)
        #expect(again.commands.first?.answers(pageKey: "g", shift: false,
                                              context: KeyContext(["paneFocused:editor": .bool(true)])) == true)
    }

    @Test func optionAndSpaceChordsStayInTheAppLayer() throws {
        let bindings = Self.bindings(Self.record(keys: [["key": "alt+shift+r", "when": "browserFocused"], ["key": "ctrl+space"]]))
        #expect(bindings.map(\.keys) == [[Shortcut("r", modifiers: [.option, .shift])], [Shortcut(" ", modifiers: [.control])]])
        #expect(KeyBindingLoader(Self.registry()).loadApp(bindings).isEmpty)
    }

    /// `contributes.keybindings` (keybindings.json form) joins the app layer: an own op as the
    /// daemon sent it (`app.command.run`), a cmux action with its arguments, a two-stroke key.
    @Test func contributedKeybindingsJoinTheAppLayer() throws {
        let record = try #require(AppRecord(json: [
            "id": "local/branchy", "installed": true,
            "manifest": ["manifestVersion": 2, "id": "local/branchy", "name": "Branchy", "version": "1.0.0"],
            "keybindings": [
                ["key": "cmd+shift+b", "command": "app.command.run", "when": "terminalFocused",
                 "args": ["app": "local/branchy", "command": "local.branchy.copy_branch"]],
                ["key": "ctrl+k s", "command": "newTab", "args": ["name": "scratch", "focus": true]],
                ["key": "hyper+b", "command": "newTab"],
            ],
        ]))
        let again = try #require(AppRecord(json: record.json))
        #expect(again.keybindings == record.keybindings)
        let bindings = AppKeyBindings.bindings([again])
        #expect(bindings.count == 2)
        #expect(bindings[0].keys == [Shortcut("b", modifiers: [.command, .shift])])
        #expect(bindings[0].command == "app.command.run")
        #expect(bindings[0].arguments == ["app": .string("local/branchy"), "command": .string("local.branchy.copy_branch")])
        #expect(bindings[0].when?.text == "terminalFocused")
        #expect(bindings[1].keys == [Shortcut("k", modifiers: [.control]), Shortcut("s", modifiers: [])])
        #expect(bindings[1].command == "newTab")
        #expect(bindings[1].arguments == ["name": .string("scratch"), "focus": .bool(true)])
        #expect(bindings.allSatisfy { $0.source == .app })
    }
}
