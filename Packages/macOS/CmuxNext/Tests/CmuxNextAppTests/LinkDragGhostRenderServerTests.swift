import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDesign
import CmuxNextTabs
import Testing

/// The link drag pill and the workspace drag ghost on the render server (chrome-parity p03-rendering-118,
/// `motion.renderServer` on), as the tab drag ghost (p03-rendering-035): inside the source window the pill is
/// a view in that window's overlay, moved per pointer event with no window call; the panel shows it only
/// outside, or where another window covers it. With the toggle off the pill is the panel, as before.
@MainActor @Suite(.serialized) struct LinkDragGhostRenderServerTests {
    /// An ordered-in window at (200, 200), 1100 x 720 (the pill fits only in a window on screen).
    static func sourceWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1100, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    static func pill(in window: NSWindow?, onServer: Bool = true) -> LinkDragGhost {
        LinkDragGhost(title: "github.com/manaflow-ai/cmux/pull/1", sourceWindow: window, rendersOnServer: onServer)
    }

    /// The source window shows every rect inside its frame in front (no other window over it).
    static func holds(_ window: NSWindow) -> (CGRect) -> Bool { { window.frame.contains($0) } }

    @Test func insideTheSourceWindowThePillFollowsThePointerWithNoWindowCall() async throws {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window)
        defer {
            ghost.close()
            window.close()
        }
        ghost.move(to: CGPoint(x: 500, y: 600), holds: Self.holds(window))
        #expect(ghost.hostName == "window", "the pill is not a view of the source window's overlay")
        #expect(!ghost.panel.isVisible, "the drag panel showed inside the source window")
        let overlay = try #require(ghost.pill.window)
        #expect(overlay !== ghost.panel)
        let start = ghost.pill.frame.origin

        let stats = RenderStats()
        try #require(stats.arm(), "this build has no render counters")
        let counting = await stats.ready()
        stats.reset()
        for step in 1...20 {
            ghost.move(to: CGPoint(x: 500 + CGFloat(step) * 4, y: 600 - CGFloat(step) * 2), holds: Self.holds(window))
        }
        let ghostWindows: [AnyClass] = [NSPanel.self, OverlayHostPanel.self]
        let calls = stats.owners().filter { owner in ghostWindows.contains { RenderStats.classKey($0) == owner.key } }
            .reduce(0) { $0 + $1.totals[.windowCalls] }
        #expect(counting, "the render counters did not install")
        #expect(calls == 0, "the pointer moves made \(calls) window calls")
        #expect(ghost.hostName == "window" && !ghost.panel.isVisible)
        #expect(ghost.pill.frame.origin == CGPoint(x: start.x + 80, y: start.y - 40), "the pill did not follow the pointer")
        // Every original IMP back before the next test arms its own counters.
        stats.disarm()
        _ = await stats.ready()
    }

    /// In the overlay the pill sits where the panel would show it: right of and below the pointer.
    @Test func theOverlayShowsThePillWhereThePanelWould() throws {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window)
        defer {
            ghost.close()
            window.close()
        }
        let pointer = CGPoint(x: 640, y: 520)
        ghost.move(to: pointer, holds: Self.holds(window))
        let overlay = try #require(ghost.pill.window)
        let shown = overlay.convertToScreen(ghost.pill.convert(ghost.pill.bounds, to: nil))
        #expect(shown == ghost.frame(at: pointer), "the pill shows at \(shown), not \(ghost.frame(at: pointer))")
        #expect(shown.minX > pointer.x && shown.maxY < pointer.y)
    }

    @Test func outsideTheSourceWindowThePanelShowsThePillAndInsideItLeaves() throws {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window)
        defer {
            ghost.close()
            window.close()
        }
        ghost.move(to: CGPoint(x: 500, y: 600), holds: Self.holds(window))
        #expect(ghost.hostName == "window")

        let outside = CGPoint(x: 1600, y: 600)
        ghost.move(to: outside, holds: nil)
        #expect(ghost.hostName == "panel" && ghost.panel.isVisible && ghost.pill.window === ghost.panel,
                "outside the window the panel holds the pill")
        let shown = ghost.panel.convertToScreen(ghost.pill.convert(ghost.pill.bounds, to: nil))
        #expect(shown == ghost.frame(at: outside), "the panel shows the pill at \(shown)")

        ghost.move(to: CGPoint(x: 500, y: 600), holds: Self.holds(window))
        #expect(ghost.hostName == "window" && !ghost.panel.isVisible, "back in the window the panel left the screen")
    }

    /// A pill that would cross the window's edge, or that another window covers, shows in the panel.
    @Test func aPillTheSourceWindowDoesNotShowWhollyGoesToThePanel() {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window)
        defer {
            ghost.close()
            window.close()
        }
        ghost.move(to: CGPoint(x: window.frame.maxX - 40, y: 600), holds: Self.holds(window))
        #expect(ghost.hostName == "panel" && ghost.panel.isVisible, "the overlay clipped the pill at the window's edge")

        let covered = CGRect(x: 600, y: 400, width: 400, height: 300)
        let holds: (CGRect) -> Bool = { window.frame.contains($0) && !covered.intersects($0) }
        ghost.move(to: CGPoint(x: 300, y: 800), holds: holds)
        #expect(ghost.hostName == "window")
        ghost.move(to: CGPoint(x: 700, y: 600), holds: holds)
        #expect(ghost.hostName == "panel", "the overlay held a pill another window covers")
    }

    /// A closed pill never shows again: a late pointer event never puts it back on screen.
    @Test func aClosedPillNeverShowsAgain() {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window)
        defer { window.close() }
        ghost.move(to: CGPoint(x: 500, y: 600), holds: Self.holds(window))
        ghost.close()
        #expect(ghost.pill.window == nil && !ghost.panel.isVisible)
        ghost.move(to: CGPoint(x: 520, y: 600), holds: Self.holds(window))
        ghost.move(to: CGPoint(x: 1600, y: 600), holds: nil)
        #expect(ghost.pill.window == nil && !ghost.panel.isVisible && ghost.hostName == "hidden")
    }

    /// With `motion.renderServer` off the pill is the panel, moved per pointer event, as before.
    @Test func offTheRenderServerThePanelFollowsThePointer() {
        let window = Self.sourceWindow()
        let ghost = Self.pill(in: window, onServer: false)
        defer {
            ghost.close()
            window.close()
        }
        ghost.move(to: CGPoint(x: 500, y: 600), holds: Self.holds(window))
        #expect(ghost.panel.isVisible && ghost.pill.window === ghost.panel && ghost.panel.hasShadow)
        #expect(ghost.panel.frame.origin == ghost.frame(at: CGPoint(x: 500, y: 600)).origin)
    }

    /// Who holds the ghost: the source window, only while the pointer is over it and it is the frontmost
    /// content window there, and only for rects no window in front of it meets. Tab, workspace and link
    /// drags ask the same rule (``TabDragSession/holds(_:at:in:)``).
    @Test func theSourceWindowHoldsTheGhostOnlyWhereItIsInFront() throws {
        let source = CGRect(x: 200, y: 200, width: 1100, height: 720)
        let other = CGRect(x: 900, y: 100, width: 600, height: 400)
        let ordered = [
            TabDragWindowPick.Candidate(frame: CGRect(x: 300, y: 300, width: 200, height: 200), controllerID: nil, occludes: false),
            TabDragWindowPick.Candidate(frame: other, controllerID: "other"),
            TabDragWindowPick.Candidate(frame: source, controllerID: "source"),
        ]
        #expect(TabDragSession.holds(nil, at: CGPoint(x: 400, y: 600), in: ordered) == nil, "a drag with no source window held")
        #expect(TabDragSession.holds("source", at: CGPoint(x: 1000, y: 300), in: ordered) == nil,
                "the source window held the ghost under another window")
        #expect(TabDragSession.holds("source", at: CGPoint(x: 1600, y: 600), in: ordered) == nil, "held outside every window")
        let holds = try #require(TabDragSession.holds("source", at: CGPoint(x: 400, y: 400), in: ordered),
                                 "a page child window over the pointer hid the source window")
        #expect(holds(CGRect(x: 400, y: 600, width: 200, height: 28)))
        #expect(!holds(CGRect(x: 850, y: 450, width: 200, height: 100)), "the other window covers the rect's corner")
        #expect(!holds(CGRect(x: 1250, y: 600, width: 200, height: 28)), "the rect leaves the source window")
    }
}
