import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Lawrence (2026-10-23): splits lag, more with Chromium pages. While a page window shows, every
/// divider hit area has a click-catching panel above the pages (`DividerMouseCatchers`). Each
/// frame of a split, close, zoom or New Column moved the dividers, so each frame moved every moving
/// divider's panel (one window server move each, a new panel for a new divider) and re-ran divider
/// hover: at 30 panes 64 % of `advanceFrame` (PL-motion-core profile, cmux10s, b553d0648b1). The
/// window's catcher areas, which every panel follows, change once when the layout lands and never
/// during the motion. Meanwhile a catcher whose divider moved lets the mouse through, a catcher
/// whose divider stays keeps taking it, and a press on a divider away from its catcher reaches the
/// divider through the press redirect (live, fluid resizing during any spring).
@MainActor @Suite(.serialized) struct DividerCatcherMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shell window whose content is a layout of two side-by-side panes, its overlay layer
    /// adopting the layout's plane, as the app wires them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()
        /// A stand-in Chromium page window over the layout (`withPage`): with it the window is in
        /// page mode (placement `.overlayWindow`) and the catcher panels are real.
        let page: NSWindow?

        /// - Parameters:
        ///   - tree: The column's split tree (two panes side by side by default).
        ///   - withPage: Shows the window and adds a page child window over the layout.
        init(_ tree: SplitNode = .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")), withPage: Bool = false) {
            _ = NSApplication.shared
            let column = LayoutColumn(id: "c", width: 1, root: tree)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            // `settle()` inline: `page` is not set yet.
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            guard withPage else {
                page = nil
                return
            }
            window.orderFrontRegardless()
            let page = NSWindow(contentRect: window.convertToScreen(root.convert(root.bounds, to: nil)), styleMask: [.borderless],
                                backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            window.addChildWindow(page, ordered: .above)
            self.page = page
        }

        func close() {
            if let page {
                window.removeChildWindow(page)
                page.orderOut(nil)
            }
            window.close()
        }

        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            return frames
        }

        var catcherAreas: [CGRect] { window.overlayLayer.catcherAreas.map(\.rect) }
        var dividerAreas: [CGRect] { window.overlayLayer.dividerAreas.map(\.rect) }
        var catchers: DividerMouseCatchers { window.overlayLayer.catchers }

        /// Ids of `resting` areas whose divider is no longer where it rested (or is gone).
        func moved(from resting: [LayoutMouseArea]) -> Set<String> {
            let now = Dictionary(window.overlayLayer.dividerAreas.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
            return Set(resting.filter { area in now[area.id].map { !sameRect($0, area.rect) } ?? true }.map(\.id))
        }
    }

    @Test func aSplitMovesNoCatcherAreaUntilItLands() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let before = layout.catcherAreas
        try #require(!before.isEmpty, "the split's divider has a catcher area: \(layout.window.overlayLayer.dividerAreas)")

        // A third pane splits off the right one: the existing divider springs left, a new one grows in.
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()

        var springFrames = 0, catcherChangesInMotion = 0, dividerChangesInMotion = 0, passThroughFrames = 0
        var lastCatchers = layout.catcherAreas, lastDividers = layout.dividerAreas
        let resting = layout.window.overlayLayer.catcherAreas
        while springFrames < 480, layout.root.advanceFrame(1.0 / 120) {
            springFrames += 1
            if layout.catcherAreas != lastCatchers { catcherChangesInMotion += 1 }
            if layout.dividerAreas != lastDividers { dividerChangesInMotion += 1 }
            // Exactly the catchers whose divider moved away let the mouse through.
            if layout.window.overlayLayer.catcherPassThrough == layout.moved(from: resting) { passThroughFrames += 1 }
            (lastCatchers, lastDividers) = (layout.catcherAreas, layout.dividerAreas)
        }
        try #require(springFrames > 4 && dividerChangesInMotion > 4, "the split animated: \(springFrames) frames, dividers moved \(dividerChangesInMotion)")
        // The frame the spring landed in returned false: the catchers follow there, once.
        #expect(catcherChangesInMotion <= 1, "catcher areas changed on \(catcherChangesInMotion) of \(springFrames) spring frames")
        #expect(layout.catcherAreas == layout.dividerAreas, "at rest the catchers cover the dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.catcherAreas.count == before.count + 1, "the new split's divider has its area at rest: \(before) -> \(layout.catcherAreas)")
        // A catcher left where its divider was must not swallow a click on the page there.
        #expect(passThroughFrames >= springFrames - 1, "the moved dividers' catchers let the mouse through on \(passThroughFrames) of \(springFrames) spring frames")
        #expect(layout.window.overlayLayer.catcherPassThrough.isEmpty, "at rest every catcher takes the mouse: \(layout.window.overlayLayer.catcherPassThrough)")
    }

    /// A root hidden mid-spring (a workspace switch during a split) settles its springs with the
    /// display link detached, so no frame reports the landing. It read as still moving when it
    /// showed again, and the window kept its catcher panels where they were (at the other
    /// workspace's dividers) until a later spring in this workspace landed: clicks on the pages
    /// under them were lost and the real dividers took no mouse over a page.
    @Test func aRootHiddenMidSpringShowsAgainWithItsCatchersAtRest() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        for _ in 0..<3 { _ = layout.root.advanceFrame(1.0 / 120) }
        try #require(layout.root.isInLayoutMotion, "the split is mid-spring")

        layout.root.isHidden = true
        #expect(!layout.root.isLive && !layout.root.isLayoutInMotion, "a parked root runs no motion")
        layout.root.isHidden = false
        try #require(layout.root.isLive, "the root shows again")

        #expect(!layout.root.isInLayoutMotion, "the settled split is at rest")
        #expect(layout.catcherAreas == layout.dividerAreas, "the catchers cover this root's dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.dividerAreas.count == 2, "both dividers of the landed split: \(layout.dividerAreas)")
        #expect(layout.window.overlayLayer.catcherPassThrough.isEmpty, "every catcher takes the mouse")
    }

    /// With a page window the catcher panels are real. A divider springs (a ratio change, as a
    /// drag's release spring) while another stays: the still divider's panel keeps taking the
    /// mouse on every spring frame (a grab of it must not go into the page), the moving one's
    /// lets it through, no panel moves or is made during the spring, and at the landing the moved
    /// panel moves once.
    @Test func aStillDividerKeepsItsCatcherWhileAnotherSprings() throws {
        let threePanes = SplitNode.split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                          b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        let layout = Layout(threePanes, withPage: true)
        defer { layout.close() }
        try #require(layout.window.overlayLayer.placement == .overlayWindow, "the page window puts the window in page mode")
        let resting = layout.window.overlayLayer.catcherAreas
        try #require(resting.count >= 2 && layout.catchers.panels.count == resting.count, "a panel per divider: \(resting)")
        let restingFrames = layout.catchers.framesInWindow
        for area in resting {
            #expect(restingFrames[area.id].map { sameRect($0, area.rect) } == true, "panel \(area.id) sits on its divider")
        }

        let narrower = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                     b: .split("t", axis: .horizontal, ratio: 0.25, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([narrower]))])
        layout.root.syncWithModel()

        let updatesBefore = layout.catchers.panelUpdates
        var springFrames = 0, stillFrames = 0, movingFrames = 0, wrongFrames = 0
        while springFrames < 480, layout.root.advanceFrame(1.0 / 120) {
            springFrames += 1
            guard layout.root.isInLayoutMotion else { break }
            let moved = layout.moved(from: resting)
            for area in resting {
                let ignores = try #require(layout.catchers.panels[area.id]).ignoresMouseEvents
                if ignores != moved.contains(area.id) { wrongFrames += 1 }
                if moved.contains(area.id) { movingFrames += 1 } else { stillFrames += 1 }
            }
            #expect(layout.catchers.panelUpdates == updatesBefore, "no panel moved or was made on spring frame \(springFrames)")
            #expect(layout.catchers.framesInWindow == restingFrames, "the panels stay at rest during the spring")
        }
        try #require(springFrames > 4 && movingFrames > 4, "the ratio change sprang: \(springFrames) frames, \(movingFrames) moving")
        #expect(stillFrames >= springFrames - 1, "the still divider was checked on \(stillFrames) of \(springFrames) frames")
        #expect(wrongFrames == 0, "a panel's ignoresMouseEvents disagreed with its divider on \(wrongFrames) checks")

        layout.settle()
        #expect(layout.catchers.panelUpdates - updatesBefore == 1, "the landing moves the one moved panel once: \(layout.catchers.panelUpdates - updatesBefore)")
        #expect(layout.catchers.panels.values.allSatisfy { !$0.ignoresMouseEvents }, "at rest every panel takes the mouse")
        for area in layout.window.overlayLayer.dividerAreas {
            #expect(layout.catchers.framesInWindow[area.id].map { sameRect($0, area.rect) } == true, "panel \(area.id) sits on its divider at rest")
        }
        #expect(layout.window.overlayLayer.motionDividerAreas.isEmpty && !layout.catchers.pressRedirect.isMonitoring,
                "no press redirect at rest")
    }

    /// A 2 -> 3 split with a page: the moved divider's and the new divider's places have no panel
    /// that takes the mouse during the spring, so the press redirect takes a press there (and its
    /// drags and release) to the parent window; a press on the page where the divider was stays
    /// with the page. At the landing a new panel counts once and the moved one once.
    @Test func aPressOnADividerAwayFromItsCatcherReachesTheDivider() throws {
        let layout = Layout(withPage: true)
        defer { layout.close() }
        let page = try #require(layout.page)
        try #require(layout.window.overlayLayer.placement == .overlayWindow, "the page window puts the window in page mode")
        let restingAreas = layout.window.overlayLayer.catcherAreas
        let redirect = layout.catchers.pressRedirect
        var forwarded: [NSEvent.EventType] = []
        redirect.forward = { event, parent in
            #expect(parent === layout.window, "a redirected event goes to the layout's window")
            forwarded.append(event.type)
        }

        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        let updatesBefore = layout.catchers.panelUpdates
        // Spring until the split's old divider is clear of where it rested.
        var pick: (resting: LayoutMouseArea, now: LayoutMouseArea)?
        for _ in 0..<480 {
            guard layout.root.advanceFrame(1.0 / 120) else { break }
            let now = Dictionary(layout.window.overlayLayer.dividerAreas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pick = restingAreas.lazy.compactMap { rest in now[rest.id].flatMap { $0.rect.intersects(rest.rect) ? nil : (rest, $0) } }.first
            if pick != nil { break }
        }
        let (resting, moved) = try #require(pick, "a resting divider moved clear of its rest mid-spring: \(restingAreas)")
        try #require(layout.root.isInLayoutMotion, "still mid-spring")
        #expect(redirect.isMonitoring, "the redirect watches presses while dividers are away from their catchers")
        #expect(layout.window.overlayLayer.motionDividerAreas.contains { $0.id == resting.id }, "the moved divider is a motion area")
        #expect(layout.catchers.panels[resting.id]?.ignoresMouseEvents == true, "its resting panel lets the mouse through")

        func event(_ type: NSEvent.EventType, at windowPoint: CGPoint) throws -> NSEvent {
            let point = page.convertPoint(fromScreen: layout.window.convertPoint(toScreen: windowPoint))
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: page.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let onDivider = CGPoint(x: moved.rect.midX, y: moved.rect.midY)
        let whereItWas = CGPoint(x: resting.rect.midX, y: resting.rect.midY)
        try #require(layout.window.overlayLayer.dividerAreas.allSatisfy { !$0.rect.contains(whereItWas) },
                     "no divider is where this one rested now: \(layout.window.overlayLayer.dividerAreas)")

        // A click on the page where the divider was is the page's.
        let pageDown = try event(.leftMouseDown, at: whereItWas)
        try #require(pageDown.window === page, "the synthesized press is the page window's")
        #expect(redirect.handle(pageDown) === pageDown, "a press on the page off every divider stays with the page")
        #expect(redirect.handle(try event(.leftMouseUp, at: whereItWas)) != nil, "and so does its release")
        #expect(forwarded.isEmpty)

        // A grab of the divider where it is now goes to the parent window, drags and release too.
        #expect(redirect.handle(try event(.leftMouseDown, at: onDivider)) == nil, "the press on the moving divider is taken")
        #expect(redirect.isPressing)
        #expect(redirect.handle(try event(.leftMouseDragged, at: onDivider.applying(.init(translationX: 30, y: 0)))) == nil)
        #expect(redirect.handle(try event(.leftMouseUp, at: onDivider.applying(.init(translationX: 30, y: 0)))) == nil)
        #expect(forwarded == [.leftMouseDown, .leftMouseDragged, .leftMouseUp], "forwarded \(forwarded)")
        #expect(!redirect.isPressing)

        layout.settle()
        #expect(!redirect.isMonitoring && layout.window.overlayLayer.motionDividerAreas.isEmpty, "no redirect at rest")
        #expect(layout.catchers.panels.count == restingAreas.count + 1 && layout.catchers.panels.values.allSatisfy { !$0.ignoresMouseEvents },
                "a panel per divider at rest (one new), each taking the mouse")
        #expect(layout.catchers.panelUpdates - updatesBefore == 2, "one move and one new panel at the landing: \(layout.catchers.panelUpdates - updatesBefore)")
    }
}

/// Equal within half a point on every edge (the overlay layer's rule for a divider still under its
/// catcher; window coordinates through a screen conversion).
private func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.maxX - b.maxX) <= 0.5 && abs(a.maxY - b.maxY) <= 0.5
}
