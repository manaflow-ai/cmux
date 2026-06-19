import Testing
import CmuxSettings
@testable import CmuxSettingsUI

@Suite("Custom command shortcut conflicts")
struct CustomCommandShortcutConflictTests {
    private func stroke(_ key: String, command: Bool = false, shift: Bool = false) -> StoredShortcut {
        StoredShortcut(first: ShortcutStroke(key: key, command: command, shift: shift))
    }

    @Test func conflictsWhenAnotherCommandUsesSameStroke() {
        let existing = ["palette.a": stroke("k", command: true)]
        let conflict = customCommandShortcutConflict(
            proposed: stroke("k", command: true),
            forCommandId: "palette.b",
            existingCommandBindings: existing,
            actionFirstStrokes: []
        )
        #expect(conflict == .command("palette.a"))
    }

    @Test func conflictsWhenAnActionUsesSameStroke() {
        let conflict = customCommandShortcutConflict(
            proposed: stroke("n", command: true),
            forCommandId: "palette.b",
            existingCommandBindings: [:],
            actionFirstStrokes: [ActionFirstStroke(stroke: ShortcutStroke(key: "n", command: true), numbered: false)]
        )
        #expect(conflict == .action)
    }

    @Test func conflictsWithActionWhenOnlyKeyCodeDiffers() {
        // Action default strokes carry `keyCode: nil`; recorded strokes carry a
        // resolved keyCode. A raw `ShortcutStroke ==` would miss this collision.
        let conflict = customCommandShortcutConflict(
            proposed: StoredShortcut(first: ShortcutStroke(key: "o", command: true, keyCode: 31)),
            forCommandId: "palette.b",
            existingCommandBindings: [:],
            actionFirstStrokes: [ActionFirstStroke(stroke: ShortcutStroke(key: "o", command: true), numbered: false)]
        )
        #expect(conflict == .action)
    }

    @Test func conflictsWithCommandWhenOnlyKeyCodeDiffers() {
        let existing = ["palette.a": StoredShortcut(first: ShortcutStroke(key: "o", command: true))]
        let conflict = customCommandShortcutConflict(
            proposed: StoredShortcut(first: ShortcutStroke(key: "o", command: true, keyCode: 31)),
            forCommandId: "palette.b",
            existingCommandBindings: existing,
            actionFirstStrokes: []
        )
        #expect(conflict == .command("palette.a"))
    }

    @Test func noConflictForDistinctStroke() {
        let conflict = customCommandShortcutConflict(
            proposed: stroke("j", command: true),
            forCommandId: "palette.b",
            existingCommandBindings: ["palette.a": stroke("k", command: true)],
            actionFirstStrokes: []
        )
        #expect(conflict == nil)
    }

    @Test func conflictsWithNumberedActionFamily() {
        // `selectSurfaceByNumber` / `selectWorkspaceByNumber` normalize their
        // stored key to the "1" placeholder but consume the whole ⌘1…9 family at
        // runtime. Binding a command to ⌘5 must be flagged, otherwise the numbered
        // action shadows it and the binding is a silent dead key.
        let conflict = customCommandShortcutConflict(
            proposed: stroke("5", command: true),
            forCommandId: "palette.b",
            existingCommandBindings: [:],
            actionFirstStrokes: [ActionFirstStroke(stroke: ShortcutStroke(key: "1", command: true), numbered: true)]
        )
        #expect(conflict == .action)
    }

    @Test func noConflictWithNumberedActionForNonDigitStroke() {
        // The numbered family only consumes digits; a non-digit command stroke in
        // the same modifier family does not collide.
        let conflict = customCommandShortcutConflict(
            proposed: stroke("t", command: true),
            forCommandId: "palette.b",
            existingCommandBindings: [:],
            actionFirstStrokes: [ActionFirstStroke(stroke: ShortcutStroke(key: "1", command: true), numbered: true)]
        )
        #expect(conflict == nil)
    }
}
