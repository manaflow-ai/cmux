import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Priority view's rows move on the sidebar's motion, which is on by default: a chat whose rank
/// changes slides to its new place, a row that leaves closes its slot (the rows below slide up), and
/// a new row opens one. Before, the move waited on `ui.animations.newWorkspace`, a switch for new
/// workspace rows, so with it off every reorder snapped and a leaving row vanished over a gap.
/// With motion off (Reduce Motion, the master switch) every change lands in one frame.
@MainActor
@Suite(.closesItsWindows)
struct SidebarPriorityMotionTests {
    /// The motion-off check only needs a screen. A test that sees a row move needs a display
    /// that draws frames (`GUIAnimationTestSupport`): a Blacksmith VM can have a screen whose
    /// display draws none, and there every change snaps, so a slide check would fail.
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The rows `ids`; those in `previews` show a preview line, so they stand taller.
    private static func panel(_ ids: [String], previews: Set<String> = []) -> SidebarPriorityPanel {
        SidebarPriorityPanel(entries: ids.map {
            SidebarPriorityEntry(id: $0, title: $0, preview: previews.contains($0) ? "the last message" : nil, state: .idle)
        })
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

    private static func near(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.5 }
    private static func near(_ r: NSRect, _ s: NSRect) -> Bool {
        near(r.minX, s.minX) && near(r.minY, s.minY) && near(r.width, s.width) && near(r.height, s.height)
    }

    /// Lets the display run frames until `done` holds (the spring settled), at most two seconds.
    private static func runFrames(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(16)) }
    }

    /// Lets the display run frames for `duration`, calling `sample` after each.
    private static func runFrames(for duration: Duration, sample: () -> Void = {}) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
            sample()
        }
    }

    /// Runs `body` with Reduce Motion pinned off and `ui.animations.newWorkspace` off (the reorder
    /// must not wait on it), then puts both back. `sidebarOff` turns the sidebar's own switch
    /// (`ui.animations.sidebar`) off. Synchronous: all of it is process-wide.
    private static func withSidebarMotion<T>(reduceMotion: Bool = false, animationsEnabled: Bool = true, sidebarOff: Bool = false,
                                             _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let (kinds, enabled, categories) = (design.enabledAnimations, design.animationsEnabled, design.disabledAnimationCategories)
        Motion.reduceMotionOverride = reduceMotion
        design.enabledAnimations.remove(.newWorkspace)
        design.animationsEnabled = animationsEnabled
        if sidebarOff { design.disabledAnimationCategories.insert(.sidebar) }
        defer {
            Motion.reduceMotionOverride = nil
            design.enabledAnimations = kinds
            design.animationsEnabled = enabled
            design.disabledAnimationCategories = categories
        }
        return try body()
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aReorderSlidesTheRowsToTheirNewPlaces() async throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let (a, c) = (try Self.row("a", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion { view.show(Self.panel(["c", "a", "b"])) }
        // The change's own frame: the rows are still on their way, not at their new slots.
        #expect(c.frame.minY > 0, "c jumped to the top instead of sliding there")
        #expect(a.frame.minY < rowHeight, "a jumped down instead of sliding")
        try await Self.runFrames { Self.near(c.frame.minY, 0) && Self.near(a.frame.minY, rowHeight) }
        #expect(Self.near(c.frame.minY, 0), "c did not reach the top slot: \(c.frame)")
        #expect(Self.near(a.frame.minY, rowHeight))
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aLeavingRowClosesItsSlotAndTheRowsBelowSlideUp() async throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let (b, c) = (try Self.row("b", in: view), try Self.row("c", in: view))
        let slot = b.frame
        Self.withSidebarMotion { view.show(Self.panel(["a", "c"])) }
        #expect(b.superview != nil, "b vanished over a gap instead of closing its slot")
        #expect(c.frame.minY > slot.minY, "c jumped up instead of sliding")
        try await Self.runFrames { b.superview == nil && Self.near(c.frame.minY, slot.minY) && c.alphaValue == 1 }
        #expect(b.superview == nil, "the closed row stayed after its move")
        #expect(Self.near(c.frame.minY, slot.minY), "c did not take b's slot: \(c.frame)")
        #expect(c.alphaValue == 1)
    }

    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aNewRowOpensItsSlot() async throws {
        let (view, window) = try Self.shown(["a", "c"])
        defer { window.closeAfterTest() }
        let c = try Self.row("c", in: view)
        let slot = c.frame
        Self.withSidebarMotion { view.show(Self.panel(["a", "b", "c"])) }
        let b = try Self.row("b", in: view)
        #expect(b.frame.height < slot.height, "b showed whole instead of opening its slot: \(b.frame)")
        #expect(c.frame.minY < slot.maxY, "c jumped down instead of sliding")
        try await Self.runFrames { Self.near(b.frame, slot) && Self.near(c.frame.minY, slot.maxY) && b.alphaValue == 1 }
        #expect(Self.near(b.frame, slot), "b did not open to c's old slot: \(b.frame)")
        #expect(Self.near(c.frame.minY, slot.maxY))
        #expect(b.alphaValue == 1)
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() },
          arguments: [(true, true, false), (false, false, false), (false, true, true)])
    func withMotionOffEveryChangeLandsInOneFrame(reduceMotion: Bool, animationsEnabled: Bool, sidebarOff: Bool) throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let (a, b, c) = (try Self.row("a", in: view), try Self.row("b", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion(reduceMotion: reduceMotion, animationsEnabled: animationsEnabled, sidebarOff: sidebarOff) {
            view.show(Self.panel(["c", "a"]))
        }
        #expect(b.superview == nil, "the leaving row stayed with motion off")
        #expect(c.frame == NSRect(x: 0, y: 0, width: c.frame.width, height: rowHeight))
        #expect(a.frame.minY == rowHeight)
        #expect(a.alphaValue == 1 && c.alphaValue == 1)
        // A row that comes back shows whole at once.
        Self.withSidebarMotion(reduceMotion: reduceMotion, animationsEnabled: animationsEnabled, sidebarOff: sidebarOff) {
            view.show(Self.panel(["c", "a", "b"]))
        }
        let back = try Self.row("b", in: view)
        #expect(back.frame.minY == rowHeight * 2 && back.frame.height == rowHeight)
        #expect(back.alphaValue == 1)
    }

    /// A second reorder while the rows still slide from the first retargets them: each ends at its
    /// place in the second order, not the first.
    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aReorderDuringASlideEndsAtTheNewPlaces() async throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let (a, b, c) = (try Self.row("a", in: view), try Self.row("b", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion { view.show(Self.panel(["c", "a", "b"])) }
        try await Self.runFrames(for: .milliseconds(80))
        #expect(!Self.near(c.frame.minY, 0), "the first slide ended before the second change")
        Self.withSidebarMotion { view.show(Self.panel(["b", "c", "a"])) }
        try await Self.runFrames { Self.near(b.frame.minY, 0) && Self.near(c.frame.minY, rowHeight) && Self.near(a.frame.minY, rowHeight * 2) }
        try await Self.runFrames(for: .milliseconds(200))
        #expect(Self.near(b.frame.minY, 0), "b: \(b.frame)")
        #expect(Self.near(c.frame.minY, rowHeight), "c: \(c.frame)")
        #expect(Self.near(a.frame.minY, rowHeight * 2), "a: \(a.frame)")
    }

    /// A change with motion off while the rows slide lands in one frame and stays: the slide in
    /// flight does not pull a row back toward its old target.
    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aChangeWithMotionOffDuringASlideLandsAndStays() async throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let (a, b, c) = (try Self.row("a", in: view), try Self.row("b", in: view), try Self.row("c", in: view))
        let rowHeight = a.frame.height
        Self.withSidebarMotion { view.show(Self.panel(["c", "a", "b"])) }
        try await Self.runFrames(for: .milliseconds(50))
        Self.withSidebarMotion(sidebarOff: true) { view.show(Self.panel(["b", "a", "c"])) }
        let landed = { Self.near(b.frame.minY, 0) && Self.near(a.frame.minY, rowHeight) && Self.near(c.frame.minY, rowHeight * 2) }
        #expect(landed(), "with motion off the change did not land at once: a \(a.frame) b \(b.frame) c \(c.frame)")
        var moved: [String] = []
        try await Self.runFrames(for: .milliseconds(600)) { if !landed() { moved.append("a \(a.frame) b \(b.frame) c \(c.frame)") } }
        #expect(moved.isEmpty, "the earlier slide moved the rows off their places: \(moved.prefix(3))")
    }

    /// A row that is still opening when its slot changes again (it gains a preview, so it stands
    /// taller) keeps clipping until it is whole: the first open's end must not unclip it while it
    /// grows, or its preview draws over the row below.
    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aRowRetargetedWhileItOpensClipsUntilWhole() async throws {
        let (view, window) = try Self.shown(["a", "c"])
        defer { window.closeAfterTest() }
        Self.withSidebarMotion { view.show(Self.panel(["a", "b", "c"])) }
        let b = try Self.row("b", in: view)
        try await Self.runFrames(for: .milliseconds(100))
        Self.withSidebarMotion { view.show(Self.panel(["a", "b", "c"], previews: ["b"])) }
        let whole = SidebarPriorityRowView.height(hasPreview: true)
        var spilled: [CGFloat] = []
        try await Self.runFrames(for: .milliseconds(900)) {
            if b.frame.height < whole - 0.5, !b.clipsToBounds { spilled.append(b.frame.height) }
        }
        #expect(spilled.isEmpty, "b drew unclipped while it opened, at heights \(spilled.prefix(3)) of \(whole)")
        #expect(Self.near(b.frame.height, whole), "b did not open whole: \(b.frame)")
        // The unclip runs in the move's completion, which a loaded main actor (the full parallel run) can deliver
        // after the window above; wait for it rather than read it at a fixed time.
        try await Self.runFrames { !b.clipsToBounds }
        #expect(!b.clipsToBounds, "b still clips after its open ended")
    }

    /// A row closing its slot takes no clicks: a right-click there must not open the menu of a
    /// chat that just left (nor a click open it).
    @Test(.enabled("needs a display that draws frames and animations on, or every change snaps anyway") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func aClosingRowTakesNoClicks() throws {
        let (view, window) = try Self.shown(["a", "b", "c"])
        defer { window.closeAfterTest() }
        let b = try Self.row("b", in: view)
        Self.withSidebarMotion { view.show(Self.panel(["a", "c"])) }
        let document = try #require(b.superview)
        #expect(b.frame.height > 2, "b closed at once: \(b.frame)")
        let inWindow = document.convert(NSPoint(x: b.frame.midX, y: b.frame.minY + 1), to: nil)
        let hit = view.hitTest(try #require(view.superview).convert(inWindow, from: nil))
        #expect(!(hit.map { $0 === b || $0.isDescendant(of: b) } ?? false), "a click on the closing row reached it: \(String(describing: hit))")
    }
}
