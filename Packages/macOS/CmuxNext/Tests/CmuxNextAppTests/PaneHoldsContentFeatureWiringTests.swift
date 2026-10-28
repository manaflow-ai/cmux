import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// A pane host the layout makes asks its root's ``LayoutRootView/holdsContentInMotion``
/// (the app's feature `paneHoldsContentInMotion` with Debug `motion.pane.holdContent` as its local override) at
/// each spring's start, and never the shared tunable store.
@MainActor
struct PaneHoldsContentFeatureWiringTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// One spring of `host` shrinking from 400 to 200 pt wide: the content's width mid-spring.
    private func widthMidSpring(_ host: PaneHostView) -> CGFloat {
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        host.restSize = CGSize(width: 200, height: 300)
        host.restOffset = CGVector(dx: 1, dy: 0)
        host.isOnLayoutSpring = true
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        let width = host.content.frame.width
        host.restOffset = .zero
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        host.isOnLayoutSpring = false
        return width
    }

    @Test func aLayoutHostAsksTheRootsSwitchAtEachSpringsStart() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))],
                                activeScreenID: "s", focusedPane: "p1")
        let panes = Panes()
        let root = LayoutRootView(model: model, contentProvider: panes, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let host = root.context.host(for: "p1")
        #expect(widthMidSpring(host) == 300, "off by default: the content follows the frame")
        var holds = true
        root.holdsContentInMotion = { holds }
        #expect(widthMidSpring(host) == 400, "on: the content keeps its starting width until the landing")
        #expect(host.content.frame.width == 200, "the landing lays it out once at its rest size")
        holds = false
        #expect(widthMidSpring(host) == 300, "the next spring reads the switch again")
    }
}
