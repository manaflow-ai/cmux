import CmuxNextActions
import CmuxNextBridge
import CmuxNextLayout

/// Up-front availability on app screens (plans/cmux-next/app-screens.md 2):
/// the actions the daemon refuses on an `app` screen (`app-screen-fixed`)
/// show disabled with the reason on that target, so menus, the palette and
/// the daemon agree. Only a daemon serving `app-screens-v1` marks screens,
/// so on any other daemon nothing here applies. Closing the screen stays
/// allowed.
enum AppScreenAvailability {
    /// Refused on an `app` screen: anything that adds, moves or closes a
    /// tab, pane or column, docks one, or sets a width (the app fills the
    /// screen, so the app reason wins over the lone column's "Add a second
    /// column first").
    static let appScreenFixed: [ActionID] = [
        "newTab", "newTab.sameKind", "newTab.page", "openBrowser", "openBrowser.webkit", "openBrowser.chromium",
        "duplicateTab", "closeTab", "closePane",
        "splitRight", "splitDown", "splitLeft", "splitUp", "splitBrowserRight", "splitBrowserDown", "newPaneAutoLayout", "newColumn", "newRow",
        "tab.moveToNewSplit", "tab.moveToNewColumn", "tab.moveToNewDockColumn", "tab.moveToWorkspace", "tab.moveToNewWindow",
        "palette.moveTabToNewWorkspace", "pane.moveToNewWorkspace",
        "moveSurfaceToPreviousPane", "moveSurfaceToNextPane", "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight",
        "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
        "swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown",
        "column.dock", "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom", "column.undock", "column.float",
        "column.moveLeft", "column.moveRight",
        "column.widthOneThird", "column.widthHalf", "column.widthTwoThirds", "column.widthFull",
        "column.cycleWidth", "column.cycleWidthBack",
    ]

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        for id in appScreenFixed {
            ActionTargetReasons.add(id, in: registry) { invocation in
                guard let (screen, _) = ColumnAvailability.resolved(invocation, ctx) else { return nil }
                return reason(for: id, screen: screen)
            }
        }
    }

    /// The refusal for running `id` on a target in `screen`, or nil.
    static func reason(for id: ActionID, screen: LayoutScreen) -> String? {
        guard case .app = screen.kind, appScreenFixed.contains(id) else { return nil }
        return RefusalStrings.appScreenFixed
    }
}
