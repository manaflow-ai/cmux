import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Chords at the key router (`ChordTracker`) and the base keymap presets
/// against the real catalog.
@MainActor
struct ShortcutChordRoutingTests {
    static let prefix = Shortcut("b", modifiers: [.control])

    static func key(_ code: UInt16, _ key: String, typing characters: String? = nil, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters ?? key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    }

    static let ctrlB = key(11, "b", typing: "\u{2}", .control)
    static let c = key(8, "c")
    static let q = key(12, "q")

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "newTab", title: "New Workspace", defaultShortcut: Shortcut("n"), category: .workspace),
        ])
        registry.bind("newTab", invoke: { _ in })
        registry.setChordOverride(ShortcutChord(prefix, Shortcut("c", modifiers: [])), for: "newTab")
        return registry
    }

    @Test func theFirstKeyArmsAndTheSecondRuns() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(chords.step(Self.ctrlB, window: ObjectIdentifier(window), registry: registry) { true } == .armed)
        #expect(chords.isPending)
        #expect(chords.step(Self.c, window: ObjectIdentifier(window), registry: registry) { true } == .run("newTab", argument: nil))
        #expect(!chords.isPending)
        #expect(chords.step(Self.c, window: ObjectIdentifier(window), registry: registry) { true } == .pass, "a lone C types")
    }

    @Test func anotherKeyEndsTheChordAndRunsNothing() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        _ = chords.step(Self.ctrlB, window: ObjectIdentifier(window), registry: registry) { true }
        #expect(chords.step(Self.q, window: ObjectIdentifier(window), registry: registry) { true } == .mismatch)
        #expect(chords.step(Self.c, window: ObjectIdentifier(window), registry: registry) { true } == .pass)
    }

    @Test func aKeyInAnotherWindowStartsOver() {
        let registry = Self.registry(), first = NSObject(), second = NSObject()
        var chords = ChordTracker()
        _ = chords.step(Self.ctrlB, window: ObjectIdentifier(first), registry: registry) { true }
        #expect(chords.step(Self.c, window: ObjectIdentifier(second), registry: registry) { true } == .pass)
        #expect(!chords.isPending)
    }

    /// A text field, browser focus mode or IME composition keeps Ctrl-B.
    @Test func focusThatTakesTextDoesNotArm() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(chords.step(Self.ctrlB, window: ObjectIdentifier(window), registry: registry) { false } == .pass)
        #expect(!chords.isPending)
    }

    /// Every action a preset binds exists, and no preset value is already
    /// the action's default (each must change something).
    @Test func presetsBindRealActionsAwayFromTheirDefaults() {
        let registry = ActionRegistry.standard()
        for preset in ShortcutKeymapPreset.allCases {
            for (id, value) in preset.overrides {
                let descriptor = registry.descriptor(for: ActionID(rawValue: id))
                #expect(descriptor != nil, "\(preset) \(id)")
                if case .stroke(let stroke)? = ShortcutBindingFormat.parse(value) {
                    #expect(SettingsApplier.shortcut(for: stroke) != descriptor?.defaultShortcut, "\(preset) \(id)")
                }
            }
        }
    }

    @Test func theKeymapActionIsBoundAndTheTmuxPreviewReadsAsTheOldApps() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        #expect(registry.isBound("palette.shortcutKeymap"))
        #expect(registry.unavailableReason(for: "palette.shortcutKeymap") == nil)
        let lines = KeymapHandlers.summary(ShortcutKeymapPreset.tmux.plan(from: [:]), registry: registry)
        #expect(lines.first == KeymapStrings.change("New Workspace", "⌘N", "⌃B C"))
        #expect(lines.contains(KeymapStrings.change("Select Workspace 1…9", "⌘1…9", "⌃B 1…9")))
        #expect(KeymapHandlers.summary(ShortcutKeymapPreset.cmux.plan(from: [:]), registry: registry) == [KeymapStrings.noChanges])
    }
}
