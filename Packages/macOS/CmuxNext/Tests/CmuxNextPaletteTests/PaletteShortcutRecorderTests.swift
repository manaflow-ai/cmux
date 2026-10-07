import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Cmd-K on a highlighted action in the palette opens an inline recorder
/// that records the next chord and saves it to cmux.json, with every
/// conflict case handled (user request: "for cmd shift p menu, we should
/// have cmd+k, edit keyboard shortcut. must handle edge cases like
/// conflicts").
@MainActor
@Suite struct PaletteShortcutRecorderTests {
    final class Editor: PaletteShortcutEditing {
        var saves: [[ShortcutChange]] = []
        var restores: [(ActionID, [ActionID])] = []
        var ghostty: [Shortcut: String] = [:]

        func environment(for event: NSEvent?) -> ShortcutEditEnvironment {
            let ghostty = ghostty
            return ShortcutEditEnvironment(ghosttyBinding: { ghostty[$0] }, chromeChords: [Shortcut("y")])
        }
        func save(_ changes: [ShortcutChange]) { saves.append(changes) }
        func restoreDefault(_ id: ActionID, unbinding others: [ActionID]) { restores.append((id, others)) }
    }

    static func action(_ id: ActionID, _ shortcut: Shortcut? = nil, requires: ActionContext = []) -> ActionDescriptor {
        ActionDescriptor(id: id, title: "Title \(id.rawValue)", defaultShortcut: shortcut, category: .workspace, requires: requires)
    }

    struct Harness {
        let controller: PaletteController
        let editor: Editor
        var registry: ActionRegistry { controller.registry }
        var model: PaletteModel { controller.model }
        var recorder: PaletteShortcutRecorder { controller.shortcutRecorder }
    }

    /// A palette over a small catalog, `selected` highlighted.
    func harness(selecting selected: ActionID = "t.plain", context: ActionContext = []) async -> Harness {
        let registry = ActionRegistry(catalog: [
            Self.action("a.plain", Shortcut("g")),
            Self.action("a.browser", Shortcut("j"), requires: [.browserFocused]),
            Self.action("quit", Shortcut("q")),
            Self.action("t.plain", Shortcut("u")),
            Self.action("t.terminal", requires: [.terminalFocused]),
        ])
        for descriptor in registry.descriptors { registry.bind(descriptor.id) {} }
        registry.context = context
        let controller = PaletteController(registry: registry, frecencyPersistence: nil)
        let editor = Editor()
        controller.shortcutRecorder.editor = editor
        controller.model.reset(to: controller.commandsPage())
        await controller.model.settle()
        controller.model.select(rowID: "action:\(selected.rawValue)")
        return Harness(controller: controller, editor: editor)
    }

    func press(_ h: Harness, _ key: String, _ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        h.recorder.handle(Shortcut(key, modifiers: modifiers), keyCode: keyCode)
    }

    func keycaps(_ h: Harness, _ id: ActionID) -> [String]? {
        h.model.rows.first { $0.item.actionID == id }?.item.keycaps
    }

    // MARK: Opening

    @Test func cmdKOnAnActionOpensTheRecorderNotTheActionsMenu() async {
        let h = await harness()
        #expect(h.model.handle(.toggleActions))
        #expect(h.model.shortcutRecorder?.actionID == "t.plain")
        #expect(h.model.shortcutRecorder?.currentKeycaps == ["⌘", "U"])
        #expect(h.model.actionsMenu == nil)
    }

    @Test func cmdKOnARowWithoutAnActionOpensTheActionsMenu() async {
        let h = await harness()
        let item = PaletteItem(id: "w", title: "Workspace", primary: PaletteCommand(id: "go", title: "Go", effect: .performKeepingOpen {}))
        h.model.reset(to: PalettePageSpec(id: "p", title: "P", placeholder: "", symbol: "x",
                                          providers: [StaticPaletteProvider(id: "s", items: [item])]))
        await h.model.settle()
        #expect(h.model.handle(.toggleActions))
        #expect(h.model.shortcutRecorder == nil)
        #expect(h.model.actionsMenu?.itemID == "w")
    }

    @Test func theActionsMenuListsEditKeyboardShortcut() async {
        let h = await harness()
        #expect(h.model.selectedItem?.allCommands.contains { $0.id == "editShortcut" } == true)
    }

    // MARK: Saving

    @Test func aFreeChordSavesAndTheRowUpdatesAtOnce() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "k", [.command, .shift], keyCode: 40)
        #expect(h.editor.saves == [[ShortcutChange("t.plain", Shortcut("k", modifiers: [.command, .shift]))]])
        #expect(h.registry.effectiveShortcut(for: "t.plain") == Shortcut("k", modifiers: [.command, .shift]))
        #expect(h.model.shortcutRecorder == nil)
        await h.model.settle()
        #expect(keycaps(h, "t.plain") == ["⇧", "⌘", "K"])
        #expect(h.model.notice?.rowID == "action:t.plain")
        #expect(h.model.notice?.text.contains("⇧⌘K") == true)
    }

    @Test func escapeCancelsWithoutSaving() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "\u{1B}", keyCode: 53)
        #expect(h.model.shortcutRecorder == nil)
        #expect(h.editor.saves.isEmpty)
        #expect(h.registry.effectiveShortcut(for: "t.plain") == Shortcut("u"))
    }

    @Test func theOpenRecorderSuspendsSystemWideHotKeysAndCancelResumesThem() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        #expect(h.registry.globalHotKeysSuspended)
        h.recorder.cancel()
        #expect(h.model.shortcutRecorder == nil)
        #expect(!h.registry.globalHotKeysSuspended)
        #expect(h.editor.saves.isEmpty)
    }

    @Test func aPageChangeWithTheRecorderOpenResumesSystemWideHotKeys() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        #expect(h.registry.globalHotKeysSuspended)
        h.controller.show(.commands)
        #expect(h.model.shortcutRecorder == nil)
        #expect(!h.registry.globalHotKeysSuspended)
    }

    @Test func closingOneOfTwoOpenRecordersKeepsHotKeysSuspended() async {
        let h = await harness()
        let other = ShortcutRecorder(registry: h.registry, state: { nil }, setState: { _ in }, didFinish: { _, _ in })
        other.editor = h.editor
        #expect(other.begin("a.plain"))
        h.model.handle(.toggleActions)
        h.recorder.cancel()
        #expect(h.registry.globalHotKeysSuspended)
        other.abandon()
        #expect(!h.registry.globalHotKeysSuspended)
    }

    @Test func pressingTheCurrentShortcutChangesNothing() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "u", [.command], keyCode: 32)
        #expect(h.editor.saves.isEmpty)
        #expect(h.model.shortcutRecorder == nil)
    }

    // MARK: Conflicts

    @Test func aConflictAsksAndEscapeKeepsBoth() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "g", [.command], keyCode: 5)
        #expect(h.model.shortcutRecorder?.pending == .set(Shortcut("g"), owners: ["a.plain"], canKeepBoth: false, canReplace: true))
        #expect(h.model.shortcutRecorder?.message?.contains("Title a.plain") == true)
        #expect(h.model.shortcutRecorder?.options == [.replace, .cancel])
        #expect(h.editor.saves.isEmpty)
        press(h, "\u{1B}", keyCode: 53)
        #expect(h.editor.saves.isEmpty)
        #expect(h.registry.effectiveShortcut(for: "a.plain") == Shortcut("g"))
    }

    @Test func returnReplacesTheOtherAction() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "g", [.command], keyCode: 5)
        press(h, "\r", keyCode: 36)
        #expect(h.editor.saves == [[ShortcutChange("t.plain", Shortcut("g")), ShortcutChange("a.plain", nil)]])
        #expect(h.registry.effectiveShortcut(for: "t.plain") == Shortcut("g"))
        #expect(h.registry.effectiveShortcut(for: "a.plain") == nil)
        #expect(h.model.shortcutRecorder == nil)
    }

    @Test func keepBothOnlyWhereTheContextsDiffer() async {
        var h = await harness()
        h.model.handle(.toggleActions)
        press(h, "g", [.command], keyCode: 5)
        press(h, "\r", [.option], keyCode: 36)
        // Same context: Keep Both is not offered and does nothing.
        #expect(h.editor.saves.isEmpty)
        #expect(h.model.shortcutRecorder?.pending != nil)

        h = await harness(selecting: "t.terminal", context: [.terminalFocused])
        h.model.handle(.toggleActions)
        press(h, "j", [.command], keyCode: 38)
        #expect(h.model.shortcutRecorder?.options == [.replace, .keepBoth, .cancel])
        press(h, "\r", [.option], keyCode: 36)
        #expect(h.editor.saves == [[ShortcutChange("t.terminal", Shortcut("j"))]])
        #expect(h.registry.effectiveShortcut(for: "a.browser") == Shortcut("j"))
    }

    @Test func refusedChordsKeepListeningWithTheReason() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        for (key, modifiers, code): (String, NSEvent.ModifierFlags, UInt16) in [("q", [.command], 12), ("x", [.option], 7), (" ", [.command], 49)] {
            press(h, key, modifiers, keyCode: code)
            #expect(h.model.shortcutRecorder != nil)
            #expect(h.model.shortcutRecorder?.pending == nil)
            #expect(h.model.shortcutRecorder?.message?.isEmpty == false)
        }
        #expect(h.model.shortcutRecorder?.message?.contains("Spotlight") == true)
        #expect(h.editor.saves.isEmpty)
    }

    @Test func aChromeChordOrGhosttyKeybindAsksBeforeSaving() async {
        let h = await harness()
        h.editor.ghostty = [Shortcut("h", modifiers: [.command, .control]): "Focus Pane Left"]
        h.model.handle(.toggleActions)
        press(h, "y", [.command], keyCode: 16)
        #expect(h.model.shortcutRecorder?.options == [.save, .cancel])
        #expect(h.editor.saves.isEmpty)
        press(h, "h", [.command, .control], keyCode: 4)
        #expect(h.model.shortcutRecorder?.message?.contains("Focus Pane Left") == true)
        press(h, "\r", keyCode: 36)
        #expect(h.editor.saves == [[ShortcutChange("t.plain", Shortcut("h", modifiers: [.command, .control]))]])
    }

    // MARK: Remove and restore

    @Test func deleteRemovesTheShortcut() async {
        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "\u{8}", keyCode: 51)
        #expect(h.editor.saves == [[ShortcutChange("t.plain", nil)]])
        #expect(h.registry.effectiveShortcut(for: "t.plain") == nil)
        await h.model.settle()
        #expect(keycaps(h, "t.plain") == nil)
    }

    @Test func shiftDeleteRestoresTheDefault() async {
        let h = await harness()
        h.registry.setShortcutOverride(Shortcut("i"), for: "t.plain")
        h.model.handle(.toggleActions)
        press(h, "\u{8}", [.shift], keyCode: 51)
        #expect(h.editor.restores.map(\.0) == ["t.plain"])
        #expect(h.registry.effectiveShortcut(for: "t.plain") == Shortcut("u"))
    }

    /// A chord-only default (the Cmd-J leader's) is a default: Restore
    /// Default is offered and brings the chord back after an unbind.
    @Test func shiftDeleteRestoresADefaultChord() async {
        let h = await harness()
        var chordOnly = Self.action("t.chord")
        chordOnly.defaultChord = ShortcutChord(Shortcut("j", modifiers: [.command]), Shortcut("j", modifiers: []))
        h.registry.seed([chordOnly])
        h.registry.bind("t.chord") {}
        h.registry.setShortcutOverride(nil, for: "t.chord")
        #expect(h.recorder.begin("t.chord"))
        #expect(h.model.shortcutRecorder?.hasDefault == true)
        press(h, "\u{8}", [.shift], keyCode: 51)
        #expect(h.editor.restores.map(\.0) == ["t.chord"])
        #expect(h.registry.effectiveChord(for: "t.chord") == chordOnly.defaultChord)
    }

    @Test func restoringADefaultAnotherActionTookAsksFirst() async {
        let h = await harness()
        h.registry.setShortcutOverride(Shortcut("i"), for: "t.plain")
        h.registry.setShortcutOverride(Shortcut("u"), for: "a.plain")
        h.model.handle(.toggleActions)
        press(h, "\u{8}", [.shift], keyCode: 51)
        #expect(h.model.shortcutRecorder?.pending == .restoreDefault(Shortcut("u"), owners: ["a.plain"], canKeepBoth: false, canReplace: true))
        press(h, "\r", keyCode: 36)
        #expect(h.editor.restores.count == 1)
        #expect(h.editor.restores.first?.1 == ["a.plain"])
        #expect(h.registry.effectiveShortcut(for: "t.plain") == Shortcut("u"))
        #expect(h.registry.effectiveShortcut(for: "a.plain") == nil)
    }

    // MARK: Keys never leak

    /// While recording, the panel takes every chord before the main menu
    /// (Cmd-N would otherwise make a workspace) and before any responder, so
    /// nothing reaches a terminal. Cmd-K itself is recorded like any chord.
    @Test func whileRecordingThePanelConsumesEveryKeyEquivalent() async {
        let panel = PalettePanel(size: CGSize(width: 400, height: 300))
        var seen: [String] = []
        panel.keyHandler = { event in
            seen.append(event.charactersIgnoringModifiers ?? "")
            return true
        }
        panel.capturesKeyEquivalents = { true }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber,
                                     context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        #expect(panel.performKeyEquivalent(with: event))
        #expect(seen == ["n"])
        panel.capturesKeyEquivalents = { false }
        panel.keyHandler = { _ in Issue.record("the handler runs only while recording"); return true }
        _ = panel.performKeyEquivalent(with: event)

        let h = await harness()
        h.model.handle(.toggleActions)
        press(h, "k", [.command], keyCode: 40)
        #expect(h.editor.saves == [[ShortcutChange("t.plain", Shortcut("k"))]])
    }
}
