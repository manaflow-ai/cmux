import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextLayout
@testable import CmuxNextTabs
import Testing

/// App screens on the app side (plans/cmux-next/app-screens.md 2, 3): the
/// actions the daemon refuses are disabled on those targets with the
/// daemon's reason, and an app column's pane has no tab strip.
@MainActor
struct AppScreenAvailabilityTests {
    private let ordinary = LayoutColumn(id: "c1", width: 0.7, root: .leaf("a"))

    private var appScreen: LayoutScreen {
        let screen = LayoutScreen(id: "s", name: "", layout: .splits(.leaf("p")))
        let column = LayoutColumn(id: screen.implicitColumnID, width: 1, root: .leaf("p"), app: "app-store")
        return LayoutScreen(id: "s", name: "", layout: .columns([column]), kind: .app("app-store"))
    }

    @Test func anAppScreenRefusesEveryTabPaneAndColumnChange() {
        let screen = appScreen
        for id in ["newTab", "splitRight", "splitDown", "newColumn", "closeTab", "closePane", "tab.moveToNewColumn",
                   "tab.moveToWorkspace", "moveSurfaceToPaneLeft", "column.dockLeft", "column.undock"] as [ActionID] {
            #expect(AppScreenAvailability.reason(for: id, screen: screen) == RefusalStrings.appScreenFixed, "\(id)")
        }
        // Width presets give the app reason, not "Add a second column first".
        for id in ["column.widthHalf", "column.cycleWidth"] as [ActionID] {
            #expect(AppScreenAvailability.reason(for: id, screen: screen) == RefusalStrings.appScreenFixed, "\(id)")
        }
        // Closing the whole screen stays allowed.
        #expect(AppScreenAvailability.reason(for: "screen.close", screen: screen) == nil)
    }

    @Test func anOrdinaryScreenRefusesNothing() {
        let screen = LayoutScreen(id: "s", name: "", layout: .columns([ordinary]))
        for id in AppScreenAvailability.appScreenFixed {
            #expect(AppScreenAvailability.reason(for: id, screen: screen) == nil)
        }
    }

    /// A misspelled id would silently get no reason: every listed id is a
    /// catalog action.
    @Test func everyListedActionExists() {
        let registry = ActionRegistry.standard()
        for id in AppScreenAvailability.appScreenFixed {
            #expect(registry.descriptor(for: id) != nil, "\(id)")
        }
    }

    /// The reasons are localized (en and ja translated).
    @Test func theReasonsAreLocalized() {
        #expect(RefusalStrings.appScreenFixed == "An app screen shows only its app")
    }

    /// An app column's pane shows the app over the whole pane: no strip, no header.
    @Test func aPaneWithoutItsStripGivesTheContentTheWholePane() {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Home")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.paneHeaderHeight > 0)
        var reported = 0
        pane.onPaneHeaderHeightChange = { reported += 1 }
        pane.showsStrip = false
        pane.layoutSubtreeIfNeeded()
        #expect(pane.paneHeaderHeight == 0)
        #expect(pane.stripView.isHidden)
        #expect(pane.contentHost.frame == pane.bounds)
        #expect(reported == 1)
        pane.showsStrip = true
        pane.layoutSubtreeIfNeeded()
        #expect(pane.contentHost.frame.minY > 0)
        #expect(!pane.stripView.isHidden)
    }
}
