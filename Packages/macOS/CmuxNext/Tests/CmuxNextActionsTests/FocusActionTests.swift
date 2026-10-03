@testable import CmuxNextActions
import Testing

/// Actions whose purpose is a view change (`ActionDescriptor.focuses`,
/// plans/cmux-next/OWNERSHIP-PRINCIPLES.md) may focus or show from any
/// origin; creating, moving and closing actions may not.
@Suite struct FocusActionTests {
    @Test func everyFocusActionIDIsInTheCatalog() {
        let ids = Set(ActionCatalog.all.map(\.id))
        let unknown = ActionCatalog.focusActionIDs.subtracting(ids)
        #expect(unknown.isEmpty, "unknown: \(unknown.map(\.rawValue).sorted())")
        #expect(ActionCatalog.all.filter(\.focuses).count == ActionCatalog.focusActionIDs.count)
    }

    @Test func focusAndSelectionActionsFocusAndCreatingActionsDoNot() {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        for id: ActionID in ["tab.focus", "palette.goToTab", "nextSurface", "focusLeft", "focusNextPane", "nextSidebarTab",
                             "selectWorkspaceByNumber", "goToWorkspace", "workspace.selectLastUsed", "showMainWindow"] {
            #expect(byID[id]?.focuses == true, "\(id)")
        }
        for id: ActionID in ["newTab", "newSurface", "splitRight", "openBrowser", "palette.moveTabToNewWorkspace", "closeTab",
                             "renameWorkspace", "workspace.newBelow", "tab.moveToNewWindow"] {
            #expect(byID[id]?.focuses == false, "\(id)")
        }
    }
}
