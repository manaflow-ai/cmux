@testable import CmuxNextDesign
import AppKit
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// User, 2026-11-09: "the hover card for the sidebar and for tabs in each pane needs to be separate
/// entities, otherwise there is weird translation animation where it flies across the whole screen".
/// One card window served every source, so a card shown for a sidebar row slid from the sidebar to a
/// pane's tab strip (and from one pane's strip to another's). A card moves only within its own source:
/// another source gets a card window of its own, and the last one fades out where it is.
@MainActor @Suite(.closesItsWindows, .serialized)
struct HoverCardSeparateSourcesTests {
    @MainActor
    private final class Source: HoverCardSource {
        let window: NSWindow
        let anchors: [HoverTargetID: CGRect]
        let hoverCardGroup: HoverCardGroup?
        init(window: NSWindow, anchors: [HoverTargetID: CGRect], group: HoverCardGroup? = nil) {
            self.window = window
            self.anchors = anchors
            hoverCardGroup = group
        }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { anchors[id] }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            let body = NSTextField(labelWithString: id.rawValue)
            return HoverCardBody(view: body, placement: .below, themeAnchor: nil) {}
        }
        func hoverCardActivated(_: HoverTargetID) {}
        func hoverCardDeactivated(_: HoverTargetID) {}
    }

    private func target(_ id: String, in window: NSWindow) -> HoverTarget {
        HoverTarget(id: HoverTargetID(id), window: window.windowNumber, delay: .zero, leave: .hides(reshow: .milliseconds(300)))
    }

    @Test func aCardNeverMovesFromTheSidebarToATabStripOrBetweenStrips() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let sidebar = Source(window: window, anchors: [HoverTargetID("ws:a"): CGRect(x: 110, y: 600, width: 200, height: 28),
                                                       HoverTargetID("ws:b"): CGRect(x: 110, y: 560, width: 200, height: 28)])
        let strip = Source(window: window, anchors: [HoverTargetID("tab:a"): CGRect(x: 600, y: 660, width: 160, height: 28)])
        let otherStrip = Source(window: window, anchors: [HoverTargetID("tab:b"): CGRect(x: 600, y: 360, width: 160, height: 28)])
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        // Every card window this test made closes: the shown one and those still fading out.
        defer { coordinator.dismiss(.action); ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() } }

        // The test holds the card windows weakly: a strong hold here kept a faded-out window alive and
        // counted it as a leak in `singleCardViolations` (the coordinator had let it go). Each pin drains
        // its autoreleased AppKit references, as a run-loop turn does in the app.
        autoreleasepool { coordinator.pin(target("ws:a", in: window), from: sidebar) }
        weak var sidebarCard = coordinator.cardWindow
        try #require(sidebarCard != nil)
        // Within one source the card is the same window: it slides from row to row.
        autoreleasepool { coordinator.pin(target("ws:b", in: window), from: sidebar) }
        #expect(coordinator.cardWindow === sidebarCard)

        autoreleasepool { coordinator.pin(target("tab:a", in: window), from: strip) }
        weak var stripCard = coordinator.cardWindow
        try #require(stripCard != nil)
        #expect(stripCard !== sidebarCard, "the sidebar's card flew to the tab strip")
        #expect(coordinator.isShowing(HoverTargetID("tab:a")))

        autoreleasepool { coordinator.pin(target("tab:b", in: window), from: otherStrip) }
        #expect(coordinator.cardWindow != nil)
        #expect(coordinator.cardWindow !== stripCard, "one pane's tab card flew to another pane's strip")
        #expect(coordinator.singleCardViolations().isEmpty, "\(coordinator.singleCardViolations())")
    }

    /// Lawrence 2026-10-20: the update card and a workspace row share one card that morphs between
    /// them. 9ae3f12 (a card window per source) gave the owner's card no source, so a workspace card
    /// after it got a new window and the update card's faded out (SidebarOneMorphingCardTests red).
    /// An owner's card is in its group: it morphs with the sidebar's rows, never with a tab strip.
    @Test func anOwnersCardMorphsWithItsGroupAndNeverWithATabStrip() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let sidebar = Source(window: window, anchors: [HoverTargetID("ws:a"): CGRect(x: 110, y: 600, width: 200, height: 28)],
                             group: .sidebar)
        let strip = Source(window: window, anchors: [HoverTargetID("tab:a"): CGRect(x: 600, y: 660, width: 160, height: 28)])
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        defer { coordinator.dismiss(.action); ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() } }
        let update = HoverTargetID("update:notes")
        func showUpdate() {
            let body = HoverCardBody(view: NSTextField(labelWithString: "notes"), placement: .beside, themeAnchor: nil) {}
            coordinator.presentOwned(update, body: body, anchor: CGRect(x: 110, y: 120, width: 200, height: 40),
                                     parent: window, group: .sidebar) {}
        }

        autoreleasepool { showUpdate() }
        weak var updateCard = coordinator.cardWindow
        try #require(updateCard != nil)
        autoreleasepool { coordinator.pin(target("ws:a", in: window), from: sidebar) }
        #expect(coordinator.cardWindow === updateCard, "the workspace card did not morph from the update card")

        autoreleasepool { coordinator.pin(target("tab:a", in: window), from: strip) }
        weak var stripCard = coordinator.cardWindow
        #expect(stripCard !== updateCard, "the sidebar's card flew to the tab strip")
        autoreleasepool { showUpdate() }
        #expect(coordinator.cardWindow !== stripCard, "the tab strip's card flew to the update card")
        // No singleCardViolations here: it counts every live card window in the process, and the
        // suite's other test leaves its own (closed, fading) windows alive until they are freed.
        #expect(coordinator.isShowingOwned(update))
    }
}
