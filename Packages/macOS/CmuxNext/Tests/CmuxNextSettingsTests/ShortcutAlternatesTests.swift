import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// Several keys for one action (https://github.com/manaflow-ai/cmux/issues/25564):
/// `{"any": [...]}` in `shortcuts.bindings` gives an action every listed key or chord,
/// from cmux.json to the key a person presses, while a two-item array stays a chord.
@MainActor @Suite(.serialized) struct ShortcutAlternatesTests {
    private static let tabs: [String: JSONValue] = [
        "nextSurface": ["any": ["ctrl+tab", "cmd+]"]],
        "prevSurface": ["any": ["ctrl+shift+tab", "cmd+["]],
    ]

    private static func snapshot(_ bindings: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["shortcuts": .object(["bindings": .object(bindings)])]), validDensities: [], validMetrics: [])
    }

    /// An applier on a registry where every catalog action is bound, as in the app.
    private static func applier() -> SettingsApplier {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return SettingsApplier(design: DesignSettings(), registry: registry)
    }

    private static func event(_ character: String, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(keyCode)
        ))
    }

    /// The action a key-down runs with `context` focused.
    private static func resolve(_ registry: ActionRegistry, _ event: NSEvent, in context: ActionContext = []) -> String? {
        registry.context = context
        return registry.resolveShortcut(for: event)?.id.rawValue
    }

    @Test(arguments: [ActionContext(), .terminalFocused, .browserFocused])
    func everyListedKeyRunsTheAction(_ context: ActionContext) throws {
        let parsed = Self.snapshot(Self.tabs)
        #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
        let applier = Self.applier()
        let diagnostics = applier.apply(parsed)
        #expect(!diagnostics.contains { $0.path.contains("Surface") }, "\(diagnostics)")
        let registry = applier.registry
        #expect(try Self.resolve(registry, Self.event("\t", kVK_Tab, [.control]), in: context) == "nextSurface")
        #expect(try Self.resolve(registry, Self.event("]", kVK_ANSI_RightBracket, [.command]), in: context) == "nextSurface")
        #expect(try Self.resolve(registry, Self.event("\t", kVK_Tab, [.control, .shift]), in: context) == "prevSurface")
        #expect(try Self.resolve(registry, Self.event("[", kVK_ANSI_LeftBracket, [.command]), in: context) == "prevSurface")
        // The first key is the one menus show.
        #expect(registry.effectiveShortcut(for: "nextSurface") == Shortcut("\t", modifiers: [.control]))
        #expect(registry.effectiveShortcut(for: "prevSurface") == Shortcut("\t", modifiers: [.control, .shift]))
    }

    @Test func aKeyTheGhosttyConfigClaimsStillRunsTheAction() throws {
        let applier = Self.applier()
        applier.apply(Self.snapshot(Self.tabs))
        let registry = applier.registry
        KeyBindingLoader(registry).loadGhostty([], claims: [Shortcut("\t", modifiers: [.control]), Shortcut("]", modifiers: [.command])])
        #expect(try Self.resolve(registry, Self.event("\t", kVK_Tab, [.control]), in: .terminalFocused) == "nextSurface")
        #expect(try Self.resolve(registry, Self.event("]", kVK_ANSI_RightBracket, [.command]), in: .terminalFocused) == "nextSurface")
    }

    @Test func removingTheListWithTheCmdTSwapOnDropsItsOtherKeys() throws {
        let swap = CmuxConfigSnapshot.parse(["tabs": ["swapCmdTAndCmdN": true]], validDensities: [], validMetrics: [])
        let applier = Self.applier()
        applier.apply(CmuxConfigSnapshot.parse(["tabs": ["swapCmdTAndCmdN": true],
                                                "shortcuts": ["bindings": ["newTab": ["any": ["cmd+t", "cmd+opt+ctrl+y"]]]]],
                                               validDensities: [], validMetrics: []))
        let ctrlOptCmdY = try Self.event("y", kVK_ANSI_Y, [.command, .option, .control])
        #expect(Self.resolve(applier.registry, ctrlOptCmdY) == "newTab")
        applier.apply(swap)
        #expect(Self.resolve(applier.registry, ctrlOptCmdY) != "newTab")
        #expect(applier.registry.alternateShortcuts["newTab"] == nil)
    }

    @Test func aNumberedFamilyTakesOneKey() {
        let applier = Self.applier()
        let diagnostics = applier.apply(Self.snapshot(["selectSurfaceByNumber": ["any": ["ctrl+1", "cmd+opt+1"]]]))
        #expect(diagnostics.contains { $0.path == "shortcuts.bindings.selectSurfaceByNumber" && $0.kind == .invalidValue })
        #expect(applier.registry.alternateShortcuts["selectSurfaceByNumber"] == nil)
        #expect(applier.registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control]))
    }

    @Test func theListedKeysReplaceTheDefaultOnes() throws {
        let applier = Self.applier()
        applier.apply(Self.snapshot(Self.tabs))
        // Cmd-Shift-] is a default key of nextSurface; the list does not name it.
        #expect(try Self.resolve(applier.registry, Self.event("]", kVK_ANSI_RightBracket, [.command, .shift])) != "nextSurface")
    }

    @Test func aChordCanBeOneOfTheKeysAndATwoItemArrayIsStillAChord() throws {
        let ctrlB = Shortcut("b", modifiers: [.control])
        let applier = Self.applier()
        applier.apply(Self.snapshot([
            "nextSurface": ["any": ["cmd+]", ["ctrl+b", "n"]]],
            "prevSurface": ["ctrl+b", "p"],
        ]))
        let registry = applier.registry
        #expect(try Self.resolve(registry, Self.event("]", kVK_ANSI_RightBracket, [.command])) == "nextSurface")
        #expect(registry.resolveChord(after: ctrlB, Shortcut("n", modifiers: []))?.id == "nextSurface")
        #expect(registry.resolveChord(after: ctrlB, Shortcut("p", modifiers: []))?.id == "prevSurface")
        #expect(registry.effectiveChord(for: "prevSurface") == ShortcutChord(ctrlB, Shortcut("p", modifiers: [])))
    }

    @Test func aPlainBindingAfterwardsDropsTheOtherKeys() throws {
        let applier = Self.applier()
        applier.apply(Self.snapshot(Self.tabs))
        applier.apply(Self.snapshot(["nextSurface": "ctrl+tab"]))
        let registry = applier.registry
        #expect(try Self.resolve(registry, Self.event("]", kVK_ANSI_RightBracket, [.command])) != "nextSurface")
        #expect(try Self.resolve(registry, Self.event("\t", kVK_Tab, [.control])) == "nextSurface")
        #expect(registry.alternateShortcuts.isEmpty)
    }

    @Test func anEmptyListUnbindsAndABadItemIsADiagnostic() throws {
        let parsed = Self.snapshot([
            "nextSurface": ["any": []],
            "prevSurface": ["any": ["ctrl+shift+tab", "cmd+nope"]],
        ])
        #expect(parsed.shortcuts["nextSurface"] == .unbound)
        #expect(parsed.shortcuts["prevSurface"] == nil)
        #expect(parsed.diagnostics.map(\.path) == ["shortcuts.bindings.prevSurface"])
        let applier = Self.applier()
        applier.apply(parsed)
        #expect(try Self.resolve(applier.registry, Self.event("\t", kVK_Tab, [.control])) != "nextSurface")
    }

    @Test func aListedKeyAnotherActionHasIsAConflictNamingThatKey() {
        let applier = Self.applier()
        let diagnostics = applier.apply(Self.snapshot(["nextSurface": ["any": ["ctrl+tab", "cmd+shift+n"]]]))
        let conflict = diagnostics.first { $0.kind == .shortcutConflict && $0.path.contains("nextSurface") }
        #expect(conflict?.path.contains("newWindow") == true, "\(diagnostics)")
        #expect(conflict?.message.hasPrefix("⇧⌘N") == true, "\(conflict?.message ?? "")")
    }

    @Test func theConfigValueReadsBackAsTheSameBinding() throws {
        let binding = try #require(ShortcutBindingFormat.parse(["any": ["ctrl+shift+tab", "cmd+[", ["ctrl+b", "p"]]]))
        guard case .alternates(let keys) = binding else { Issue.record("not alternates: \(binding)"); return }
        #expect(keys.count == 3)
        #expect(ShortcutBindingFormat.parse(ShortcutBindingFormat.configValue(binding)) == binding)
    }
}
