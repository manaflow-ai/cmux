import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// Config script key modes and actions in the app (scripting-runtime.md section 10.3).
@MainActor @Suite struct ScriptKeyModesTests {
    private func mode(_ name: String, exclusive: Bool = true) -> ScriptConfigReport.Mode {
        ScriptConfigReport.Mode(name: name, title: name.capitalized, exclusive: exclusive)
    }

    @Test func aModeRegistersItsEnterActionAndItsKeysWorkOnlyWhileOn() {
        let registry = ActionRegistry.standard()
        let modes = ScriptKeyModes()
        modes.registry = registry
        let ids = modes.load([mode("window")])
        #expect(ids == [ScriptKeyModes.enterID("window"), ScriptKeyModes.exitID])
        modes.bindings = ["window": [KeyBinding(keys: [Shortcut("h", modifiers: [])], command: "focusLeft", source: .app)]]
        let context = KeyContext()
        #expect(modes.binding(for: [Shortcut("h", modifiers: [])], in: context) == nil)
        #expect(registry.perform(ScriptKeyModes.enterID("window")))
        #expect(modes.active == "window" && modes.isExclusive)
        #expect(modes.binding(for: [Shortcut("h", modifiers: [])], in: context)?.command == "focusLeft")
        #expect(modes.binding(for: [Shortcut("j", modifiers: [])], in: context) == nil)
        modes.exit()
        #expect(modes.active == nil)
    }

    @Test func aModeThatIsGoneEnds() {
        let modes = ScriptKeyModes()
        modes.registry = ActionRegistry.standard()
        _ = modes.load([mode("resize", exclusive: false)])
        modes.enter("resize")
        #expect(modes.active == "resize" && !modes.isExclusive)
        _ = modes.load([])
        #expect(modes.active == nil)
    }

    @Test func theOriginSaysKeyPaletteOrTheCaller() {
        var key = ActionInvocation()
        key.keyContext = []
        #expect(ScriptConfigController.origin(key) == "key")
        #expect(ScriptConfigController.origin(ActionInvocation()) == "palette")
        var cli = ActionInvocation()
        cli.origin = .cli
        #expect(ScriptConfigController.origin(cli) == "cli")
    }

    @Test func aScriptActionTakesTheArgumentsItsBindingPasses() {
        let registry = ActionRegistry.standard()
        var action = Action(id: "user.go", title: "Go", handler: {})
        action.takesAnyArguments = true
        registry.register(action)
        registry.register(Action(id: "plain.adhoc", title: "Plain", handler: {}))
        let loader = KeyBindingLoader(registry)
        let keys = [Shortcut("g", modifiers: [.command])]
        guard case .success = loader.validated(KeyBinding(keys: keys, command: "user.go", arguments: ["n": .int(2)], source: .app)) else {
            Issue.record("a script action's arguments were refused")
            return
        }
        guard case .failure = loader.validated(KeyBinding(keys: keys, command: "plain.adhoc", arguments: ["n": .int(2)], source: .app)) else {
            Issue.record("an ad hoc action without arguments took some")
            return
        }
    }

    @Test func aKeyFunctionStaysOutOfThePalette() {
        let registry = ActionRegistry.standard()
        var hidden = Action(id: "user.key.1", title: "cmd+k h", handler: {})
        hidden.paletteExemption = .scriptKeyFunction
        registry.register(hidden)
        registry.register(Action(id: "user.hi", title: "Hi", handler: {}))
        let entries = Dictionary(registry.entries.map { ($0.descriptor.id, $0.descriptor) }, uniquingKeysWith: { first, _ in first })
        #expect(entries["user.key.1"]?.isPaletteVisible == false)
        #expect(entries["user.hi"]?.isPaletteVisible == true)
    }
}
