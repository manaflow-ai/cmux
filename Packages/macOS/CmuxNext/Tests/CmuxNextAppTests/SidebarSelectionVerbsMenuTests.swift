import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// The sidebar's multi-selection verbs, as Chrome's on several selected tabs (Leo 2026-10-20):
/// Close Other and Close Below keep the whole selection, and Cmd-W in the sidebar closes it.
@MainActor
struct SidebarSelectionVerbsMenuTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func closeOtherKeepsEverySelectedRow() {
        #expect(WorkspaceBulkClose.keeping(["b", "d"], id: "palette.closeOtherWorkspaces", order: order) == ["a", "c", "e"])
    }

    @Test func closeBelowClosesTheRowsBelowTheLastSelectedOne() {
        #expect(WorkspaceBulkClose.keeping(["b", "c"], id: "palette.closeWorkspacesBelow", order: order) == ["d", "e"])
        #expect(WorkspaceBulkClose.keeping(["b", "e"], id: "palette.closeWorkspacesBelow", order: order).isEmpty)
    }

    @Test func closeAboveClosesTheRowsAboveTheFirstSelectedOne() {
        #expect(WorkspaceBulkClose.keeping(["c", "d"], id: "palette.closeWorkspacesAbove", order: order) == ["a", "b"])
    }

    /// One row kept is the one-row verb it always was.
    @Test func oneKeptRowClosesAsBefore() {
        #expect(WorkspaceBulkClose.keeping(["c"], id: "palette.closeOtherWorkspaces", order: order) == ["a", "b", "d", "e"])
        #expect(WorkspaceBulkClose.keeping(["c"], id: "palette.closeWorkspacesBelow", order: order) == ["d", "e"])
        #expect(WorkspaceBulkClose.keeping(["c"], id: "palette.closeWorkspacesAbove", order: order) == ["a", "b"])
        #expect(WorkspaceBulkClose.keeping(["z"], id: "palette.closeOtherWorkspaces", order: order).isEmpty)
    }

    /// `sidebar.multiSelection` holds only while the sidebar list has the keyboard with two or more rows selected.
    @Test func theSidebarMultiSelectionKeyNeedsSidebarFocus() {
        var sidebar = FocusState()
        sidebar.resolved = .sidebar
        let many = KeyFacts(sidebarMultiSelection: true)
        #expect(KeyRouter.keyContext(for: sidebar, appContext: [], facts: many)[KeyContext.sidebarMultiSelection] == .bool(true))
        #expect(KeyRouter.keyContext(for: sidebar, appContext: [], facts: KeyFacts())[KeyContext.sidebarMultiSelection] == nil)
        var field = FocusState()
        field.resolved = .sidebarField
        #expect(KeyRouter.keyContext(for: field, appContext: [], facts: many)[KeyContext.sidebarMultiSelection] == nil)
        #expect(KeyRouter.keyContext(for: FocusState(), appContext: [], facts: many)[KeyContext.sidebarMultiSelection] == nil)
    }

    /// Cmd-W closes the selected workspaces from the sidebar, and the shown tab everywhere else.
    @Test(arguments: [
        ([KeyContext.sidebarMultiSelection: KeyContextValue.bool(true), KeyContext.focus: .string("sidebar")], "closeWorkspace"),
        ([KeyContext.focus: KeyContextValue.string("sidebar")], "closeTab"),
        ([KeyContext.focus: KeyContextValue.string("content"), KeyContext.surfaceKind: .string("terminal")], "closeTab"),
    ])
    func cmdWClosesTheSelectionFromTheSidebar(context: [String: KeyContextValue], command: String) {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        let table = RegistryKeyBindings(registry).table
        let winner = table.resolve([Shortcut("w", modifiers: [.command])], in: KeyContext(context), isRunnable: { _ in true }).winner
        #expect(winner?.command.rawValue == command)
    }
}
