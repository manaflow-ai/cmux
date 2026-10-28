import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import Testing

/// Ctrl-Cmd-X expands the folded panes (Lawrence 2026-10-28: a pane folds into a bar "that expands on click or a
/// shortcut"): a key no Ghostty default and no other cmux default takes, resolved in every focus.
@MainActor @Suite struct ExpandCollapsedPanesKeyTests {
    nonisolated static let contexts: [ActionContext] = [[], .terminalFocused, .browserFocused, .markdownFocused, .agentPaneFocused]

    @Test(arguments: contexts)
    func ctrlCmdXExpandsFoldedPanes(context: ActionContext) throws {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X)
        ))
        #expect(registry.resolveShortcut(for: event)?.id.rawValue == "pane.expandCollapsed")
    }

    @Test func theDefaultIsCtrlCmdXAndNoOtherActionHasIt() {
        let registry = ActionRegistry.standard()
        let key = Shortcut("x", modifiers: [.control, .command])
        #expect(registry.effectiveShortcut(for: "pane.expandCollapsed") == key)
        let others = ActionCatalog.all.filter { $0.id.rawValue != "pane.expandCollapsed" && registry.effectiveShortcut(for: $0.id) == key }
        #expect(others.isEmpty, "\(others.map(\.id))")
    }
}
