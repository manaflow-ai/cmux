import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The Priority view's rows move on the sidebar's motion, which is on by default: a chat whose rank
/// changes slides to its new place, a row that leaves closes its slot (the rows below slide up), and
/// a new row opens one. Before, the move waited on `ui.animations.newWorkspace`, a switch for new
/// workspace rows, so with it off every reorder snapped and a leaving row vanished over a gap.
/// With motion off (Reduce Motion, the master switch) every change lands in one frame.
@MainActor
struct SidebarPriorityMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    private static func panel(_ ids: [String]) -> SidebarPriorityPanel {
        SidebarPriorityPanel(entries: ids.map { SidebarPriorityEntry(id: $0, title: $0, state: .idle) })
    }

    /// A panel showing `ids`, in a window on screen (with no screen Motion snaps every change).
    private static func shown(_ ids: [String]) throws -> (SidebarPriorityPanelView, NSWindow) {
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.show(panel(ids))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private static func rows(in view: NSView) -> [SidebarPriorityRowView] {
        view.subviews.flatMap { ($0 as? SidebarPriorityRowView).map { [$0] } ?? rows(in: $0) }
    }

    private static func row(_ id: String, in view: NSView) throws -> SidebarPriorityRowView {
        try #require(rows(in: view).first { $0.entry.id == id }, "no row for \(id)")
    }

    private static func moving(_ row: NSView) -> Bool { !(row.layer?.animationKeys() ?? []).isEmpty }

    /// Runs `body` with Reduce Motion pinned off and `ui.animations.newWorkspace` off (the reorder
    /// must not wait on it), then puts both back. Synchronous: both are process-wide.
    private static func withSidebarMotion<T>(reduceMotion: Bool = false, animationsEnabled: Bool = true,
                                             _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let (kinds, enabled) = (design.enabledAnimations, design.animationsEnabled)
        Motion.reduceMotionOverride = reduceMotion
        design.enabledAnimations.remove(.newWorkspace)
        design.animationsEnabled = animationsEnabled
        defer {
            Motion.reduceMotionOverride = nil
            design.enabledAnimations = kinds
            design.animationsEnabled = enabled
        }
        return try body()
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aReorderSlidesTheRowsToTheirNewPlaces() throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.orderOut(nil) }
        let (a, c) = (try Self.row("a", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion { view.show(Self.panel(["c", "a", "b"])) }
        #expect(c.frame.minY == 0, "c did not take the top slot")
        #expect(a.frame.minY == rowHeight)
        #expect(Self.moving(c), "c jumped to the top instead of sliding there")
        #expect(Self.moving(a), "a jumped down instead of sliding")
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aLeavingRowClosesItsSlotAndTheRowsBelowSlideUp() throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.orderOut(nil) }
        let (b, c) = (try Self.row("b", in: view), try Self.row("c", in: view))
        let slot = b.frame
        Self.withSidebarMotion { view.show(Self.panel(["a", "c"])) }
        #expect(b.superview != nil, "b vanished over a gap instead of closing its slot")
        #expect(b.frame.minY == slot.minY && b.frame.height == 0, "b does not close at its slot: \(b.frame)")
        #expect(Self.moving(b))
        #expect(c.frame.minY == slot.minY, "c does not take b's slot")
        #expect(Self.moving(c), "c jumped up instead of sliding")
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aNewRowOpensItsSlot() throws {
        let (view, window) = try Self.shown(["a", "c"])
        defer { window.orderOut(nil) }
        let c = try Self.row("c", in: view)
        let slot = c.frame
        Self.withSidebarMotion { view.show(Self.panel(["a", "b", "c"])) }
        let b = try Self.row("b", in: view)
        #expect(b.frame == slot, "b does not open at c's old slot: \(b.frame)")
        #expect(Self.moving(b), "b showed whole instead of opening its slot")
        #expect(c.frame.minY == slot.maxY)
        #expect(Self.moving(c), "c jumped down instead of sliding")
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() },
          arguments: [(true, true), (false, false)])
    func withMotionOffEveryChangeLandsInOneFrame(reduceMotion: Bool, animationsEnabled: Bool) throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.orderOut(nil) }
        let (a, b, c) = (try Self.row("a", in: view), try Self.row("b", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion(reduceMotion: reduceMotion, animationsEnabled: animationsEnabled) {
            view.show(Self.panel(["c", "a"]))
        }
        #expect(b.superview == nil, "the leaving row stayed with motion off")
        #expect(c.frame == NSRect(x: 0, y: 0, width: c.frame.width, height: rowHeight))
        #expect(a.frame.minY == rowHeight)
        for row in [a, c] {
            #expect(!Self.moving(row), "\(row.entry.id) animates with motion off")
            #expect(row.alphaValue == 1)
        }
        // A row that comes back shows whole at once.
        Self.withSidebarMotion(reduceMotion: reduceMotion, animationsEnabled: animationsEnabled) {
            view.show(Self.panel(["c", "a", "b"]))
        }
        let back = try Self.row("b", in: view)
        #expect(back.frame.minY == rowHeight * 2 && back.frame.height == rowHeight)
        #expect(back.alphaValue == 1 && !Self.moving(back))
    }
}
