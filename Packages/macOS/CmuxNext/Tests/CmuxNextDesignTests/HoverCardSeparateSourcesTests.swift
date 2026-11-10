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
        init(window: NSWindow, anchors: [HoverTargetID: CGRect]) {
            self.window = window
            self.anchors = anchors
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
        defer { coordinator.dismiss(.action) }

        coordinator.pin(target("ws:a", in: window), from: sidebar)
        let sidebarCard = try #require(coordinator.cardWindow)
        // Within one source the card is the same window: it slides from row to row.
        coordinator.pin(target("ws:b", in: window), from: sidebar)
        #expect(coordinator.cardWindow === sidebarCard)

        coordinator.pin(target("tab:a", in: window), from: strip)
        let stripCard = try #require(coordinator.cardWindow)
        #expect(stripCard !== sidebarCard, "the sidebar's card flew to the tab strip")
        #expect(coordinator.isShowing(HoverTargetID("tab:a")))

        coordinator.pin(target("tab:b", in: window), from: otherStrip)
        #expect(coordinator.cardWindow !== stripCard, "one pane's tab card flew to another pane's strip")
        #expect(coordinator.singleCardViolations().isEmpty, "\(coordinator.singleCardViolations())")
    }
}
