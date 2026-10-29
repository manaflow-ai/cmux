import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// Content that follows its pane's place in the window (a page's glass lens)
/// hears a finished move once, never per frame: a strip camera that only moves the panes (no layout spring, so
/// no `PaneMotionSettling`) still ends in one `PanePlacementFollowing` call. A layout spring's start says whether
/// the host's frame is already at rest: only on the render server (`PaneHostView.placeAtRest`).
@MainActor
struct PanePlacementSettleTests {
    /// A page-like leaf: what it heard, and whether its host's frame was at rest at each spring start.
    final class Follower: NSView, PanePlacementFollowing, PaneMotionTargeting, PaneMotionSettling {
        var placements = 0
        var landings = 0
        var startsAtRest: [Bool] = []

        func panePlacementDidSettle() { placements += 1 }
        func paneMotionDidSettle() { landings += 1 }
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            startsAtRest.append(enclosingFramePlacedAtRest)
            return .top
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var followers: [PaneID: Follower] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let follower = Follower()
            followers[pane] = follower
            return follower
        }
    }

    final class Strip {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ screens: [LayoutScreen], focused: PaneID) {
            model = LayoutModel(screens: screens, activeScreenID: "s", focusedPane: focused)
            model.rowsEnabledOverride = true
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { false },
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            stepToRest()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        /// Steps the springs until they rest; returns the placements heard in frames that still moved.
        @discardableResult
        func stepToRest() -> Int {
            var heardInMotion = 0
            for _ in 0..<600 {
                let before = placements
                let moving = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                guard moving else { break }
                heardInMotion += placements - before
            }
            return heardInMotion
        }

        var placements: Int { panes.followers.values.reduce(0) { $0 + $1.placements } }

        func reset() {
            for follower in panes.followers.values {
                follower.placements = 0
                follower.landings = 0
                follower.startsAtRest = []
            }
        }
    }

    static func columns(_ count: Int, width: Double = 0.5) -> [LayoutScreen] {
        let layout = ScreenLayout.columns((1...count).map { LayoutColumn(id: ColumnID("c\($0)"), width: width, root: .leaf(PaneID("p\($0)"))) })
        return [LayoutScreen(id: "s", name: "s", layout: layout)]
    }

    /// The strip camera moves every pane on every frame with no layout spring: the content hears nothing per
    /// frame and one settle per moved pane when the camera lands, and no `PaneMotionSettling` landing.
    @Test func aStripCameraMoveSettlesEachPaneOnceWhenItLands() throws {
        let strip = Strip(Self.columns(4, width: 0.4), focused: PaneID("p1"))
        defer { strip.window.close() }
        let follower = try #require(strip.panes.followers[PaneID("p3")])
        let before = follower.convert(follower.bounds, to: nil)
        strip.reset()

        strip.model.focus(PaneID("p4"), notify: false)
        strip.root.syncWithModel()
        try #require(abs(strip.screen.scroll.target - strip.screen.scroll.value) > 50, "focusing p4 does not move the camera")
        let heardInMotion = strip.stepToRest()

        #expect(heardInMotion == 0, "the camera's frames told the content \(heardInMotion) settles")
        #expect(follower.convert(follower.bounds, to: nil).minX < before.minX - 50, "p3 did not move")
        #expect(follower.placements == 1, "p3 heard \(follower.placements) settles, not one")
        #expect(strip.panes.followers.values.allSatisfy { $0.placements <= 1 }, "a pane heard the landing twice")
        #expect(follower.landings == 0, "a camera move is not a layout spring")

        // Nothing moved since: nothing more.
        strip.root.syncWithModel()
        strip.stepToRest()
        #expect(follower.placements == 1, "a layout pass that moved nothing settled p3 again")
    }

    /// A pane that only moves at rest (animation off: a column closed beside it) hears it settle in the change's turn.
    @Test func aMoveWithNoAnimationSettlesInItsTurn() throws {
        let third = 1.0 / 3
        let strip = Strip(Self.columns(3, width: third), focused: PaneID("p1"))
        defer { strip.window.close() }
        strip.root.context.reduceMotionOverride = true
        let follower = try #require(strip.panes.followers[PaneID("p3")])
        let before = follower.convert(follower.bounds, to: nil)
        strip.reset()

        strip.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: ColumnID("c1"), width: third, root: .leaf(PaneID("p1"))),
            LayoutColumn(id: ColumnID("c3"), width: third, root: .leaf(PaneID("p3"))),
        ]))])
        strip.root.syncWithModel()
        strip.root.layoutSubtreeIfNeeded()
        try #require(follower.convert(follower.bounds, to: nil).minX < before.minX - 100, "p3 did not move left")
        #expect(follower.placements == 1, "p3 moved at rest and heard \(follower.placements) settles")
    }

    /// A CPU split's start tells the content its host's frame is not at rest yet; the spring's landing settles
    /// the place once.
    @Test func aCPUSpringStartsAwayFromRestAndSettlesOnce() throws {
        let strip = Strip(PaneMotionBench.grid(2, 1), focused: PaneID("p0-0"))
        defer { strip.window.close() }
        let follower = try #require(strip.panes.followers[PaneID("p0-0")])
        strip.reset()

        strip.model.apply(screens: PaneMotionBench.split(2, 1, axis: .horizontal))
        strip.root.syncWithModel()
        let heardInMotion = strip.stepToRest()

        #expect(follower.startsAtRest == [false], "the CPU split's start said \(follower.startsAtRest)")
        #expect(heardInMotion == 0, "the spring's frames told the content \(heardInMotion) settles")
        #expect(follower.landings == 1)
        #expect(follower.placements <= 1, "p0-0 heard \(follower.placements) settles")
    }

    /// A render-server spring sets the host's frame at rest when it starts: its content hears it is at rest.
    @Test func aRenderServerStartIsAtRest() {
        let follower = Follower()
        let host = PaneHostView(pane: PaneID("p"), content: follower)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(host)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        host.restSize = host.frame.size
        host.layoutSubtreeIfNeeded()

        host.placeAtRest(SplitMotion.RenderMove(from: host.frame, to: NSRect(x: 0, y: 0, width: 400, height: 200), fromAlpha: 1, toAlpha: 1),
                         laysOut: true)

        #expect(follower.startsAtRest == [true], "the render-server start said \(follower.startsAtRest)")
        #expect(host.framePlacedAtRest)
    }
}
