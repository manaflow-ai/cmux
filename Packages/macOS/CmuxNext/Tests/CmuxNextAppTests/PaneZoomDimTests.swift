import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The light around a zoom (Cmd-Shift-Enter): the other panes dim, and no frame shows a pane between two layouts.
///
/// - At the zoom key nothing moves: the screen shows the layout before the zoom, whole, and a dim comes over the other
///   panes. When the dim's fade is over, one frame shows the zoomed pane alone at its screen's size, and the dim is gone.
/// - An unzoom shows every pane at its place in one frame, the other panes under the dim, which then fades out.
/// - A second key while the dim comes ends it at once.
/// - With no pane animation (Reduce Motion) there is no dim, and each change shows in its first frame.
///
/// The dim is one view of the layout's overlay plane, found by its identifier, with one layer whose opacity is the
/// dim and whose sublayers leave a hole over the pane that zooms. The oracle for the panes is the layout engine's rest
/// geometry (`PaneLayoutCommitTests.Rest`), and the test is the clock: it steps the layout's frames itself.
@MainActor
@Suite(.closesItsWindows) struct PaneZoomDimTests {
    typealias Commit = PaneLayoutCommitTests
    typealias Zoom = PaneZoomMotionTests

    static let dt = PaneMotionBench.frameBudget

    /// The dim as it shows now: its view in the overlay plane and the layer that carries its opacity.
    static func dim(_ harness: Commit.Harness) -> (view: NSView, layer: CALayer)? {
        guard let view = harness.root.overlayPlane.subviews.first(where: { $0.identifier?.rawValue == "pane.zoom.dim" }),
              let layer = view.layer?.sublayers?.first else { return nil }
        return (view, layer)
    }

    /// Where the panes of one layout show, in the layout root's coordinates: the content rect of the pane that the dim
    /// must leave clear, and the middle of each pane that it must cover.
    struct Places {
        var clear: (pane: PaneID, hole: CGRect)
        var covered: [(pane: PaneID, middle: CGPoint)]
    }

    /// The places of `pane` and `others` as they show now. Each of them must have its host in the layout: a zoom takes
    /// the panes it covers out of the layout's hosts in its own turn, so a test of a zoom reads the places before it.
    static func places(clear pane: PaneID, over others: [PaneID], in harness: Commit.Harness) throws -> Places {
        let root = harness.root
        let host = try #require(root.context.hosts[pane], "\(pane) has no host")
        var covered: [(pane: PaneID, middle: CGPoint)] = []
        for other in others {
            let shown = try #require(root.context.hosts[other], "\(other) has no host")
            let frame = root.convert(shown.bounds, from: shown)
            covered.append((other, CGPoint(x: frame.midX, y: frame.midY)))
        }
        return Places(clear: (pane, root.convert(host.contentRect, from: host)), covered: covered)
    }

    /// What is wrong with where the dim is, against the places where the panes show: it must leave the one pane clear
    /// and cover the middle of each other pane.
    static func misses(_ dim: (view: NSView, layer: CALayer), _ places: Places) -> [String] {
        let parts = (dim.layer.sublayers ?? []).map { $0.frame.offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY) }
        var found: [String] = []
        for part in parts where part.intersects(places.clear.hole.insetBy(dx: 1, dy: 1)) {
            found.append("the dim covers \(places.clear.pane) at \(part)")
        }
        for other in places.covered where !parts.contains(where: { $0.contains(other.middle) }) {
            found.append("the dim does not cover \(other.pane)")
        }
        return found
    }

    /// The fade of the dim on the Mac that runs the test: the pane veil's (`MotionFade.paneDim`).
    static func fade() throws -> TimeInterval {
        let duration = Motion.panes.duration(.paneDim)
        try #require(duration > 0 && duration <= 0.3, "SETUP: the pane veil's fade is \(duration) s on this Mac")
        return duration
    }

    @Test func aZoomDimsTheOtherPanesBeforeItShowsWhole() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let duration = try Self.fade()
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)
        #expect(Self.dim(harness) == nil, "a dim shows at rest")
        // The grid's places, read while each pane has its host: the zoom's own turn must leave every pane there.
        let places = try Self.places(clear: "p4", over: ["p1", "p2", "p3"], in: harness)

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        // The key's own turn: nothing moved, and the dim comes over the other panes.
        #expect(grid.isShown(by: Commit.shown(screen)), "the zoom's own turn changed what the screen shows")
        let dim = try #require(Self.dim(harness), "the zoom's own turn shows no dim over the other panes")
        #expect(dim.layer.opacity > 0.05 && dim.layer.opacity < 0.9, "the dim's strength is \(dim.layer.opacity)")
        // The dim comes on a fade from nothing: with no fade on its layer a person sees it jump to its full strength.
        let coming = try #require(dim.layer.animation(forKey: "opacity") as? CABasicAnimation, "the dim comes with no fade on its layer")
        #expect((coming.fromValue as? Float) == 0 && abs(coming.duration - duration) < 1e-6,
                "the dim's fade is not from nothing over \(duration) s: from \(String(describing: coming.fromValue)) over \(coming.duration) s")
        let off = Self.misses(dim, places)
        #expect(off.isEmpty, "\(off)")

        // Each frame shows the grid, whole, under the dim, until one frame shows the zoomed pane alone with no dim.
        var shownAt: Int?
        for tick in 1...Commit.frames {
            let asks = harness.root.advanceFrame(Self.dt)
            let frame = Commit.shown(screen)
            if zoomed.isShown(by: frame) {
                if shownAt == nil { shownAt = tick }
                #expect(Self.dim(harness) == nil, "tick \(tick): the dim still shows with the zoomed pane")
                #expect(!asks, "tick \(tick): a zoom that showed asks for frames")
            } else {
                #expect(shownAt == nil && grid.isShown(by: frame), "tick \(tick) shows neither layout, or the grid again: \(frame.panes)")
                #expect(Self.dim(harness) != nil, "tick \(tick): the dim went before the zoom showed")
                #expect(asks, "tick \(tick): the zoom waits and asks for no frame")
            }
            #expect(frame.misfits.isEmpty, "tick \(tick): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
        }
        let at = try #require(shownAt, "the zoom never showed")
        #expect(at >= 2 && Double(at) * Self.dt <= 0.3 && abs(Double(at) * Self.dt - duration) <= Self.dt + 1e-6,
                "the zoom showed at tick \(at) (\(Double(at) * Self.dt) s); the dim's fade is \(duration) s")
        #expect(harness.provider.released.isEmpty, "the zoom released a pane: \(harness.provider.released)")
    }

    @Test func anUnzoomShowsEveryPaneUnderADimThatFades() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let duration = try Self.fade()
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        Commit.rest(harness)
        try #require(zoomed.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "SETUP: the zoom did not come to rest with no dim")

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        #expect(zoomed.isShown(by: Commit.shown(screen)), "the unzoom's own turn changed what the screen shows")
        // The frame that shows the unzoom: every pane at its place, the other panes under the dim, which fades out.
        let asks = harness.root.advanceFrame(Self.dt)
        #expect(grid.isShown(by: Commit.shown(screen)), "the first frame after the unzoom does not show every pane at its place")
        let dim = try #require(Self.dim(harness), "the frame that shows the unzoom shows no dim over the other panes")
        #expect(dim.layer.opacity == 0, "the dim does not fade out: it goes to \(dim.layer.opacity)")
        // It goes on a fade from its full strength: with no fade on its layer a person sees no dim at all.
        let going = try #require(dim.layer.animation(forKey: "opacity") as? CABasicAnimation, "the dim goes with no fade on its layer")
        #expect(((going.fromValue as? Float) ?? 0) > 0.05 && abs(going.duration - duration) < 1e-6,
                "the dim's fade is not from its strength over \(duration) s: from \(String(describing: going.fromValue)) over \(going.duration) s")
        let places = try Self.places(clear: "p4", over: ["p1", "p2", "p3"], in: harness)
        let off = Self.misses(dim, places)
        #expect(off.isEmpty, "\(off)")
        #expect(asks, "the frame that shows the unzoom asks for no frame for the dim's fade")
        #expect(!harness.root.isInLayoutMotion, "the dim's fade counts as a motion of the layout")

        var goneAt: Int?
        for tick in 2...Commit.frames {
            let asks = harness.root.advanceFrame(Self.dt)
            #expect(grid.isShown(by: Commit.shown(screen)), "tick \(tick): a pane moved while the dim faded")
            if Self.dim(harness) == nil {
                if goneAt == nil { goneAt = tick }
                #expect(!asks, "tick \(tick): frames run on after the dim went")
            } else {
                #expect(goneAt == nil, "tick \(tick): the dim came back")
                #expect(asks, "tick \(tick): the dim still shows and no frame is asked for")
            }
        }
        let gone = try #require(goneAt, "the dim never went")
        #expect(Double(gone) * Self.dt <= 0.3 && abs(Double(gone - 1) * Self.dt - duration) <= Self.dt + 1e-6,
                "the dim went at tick \(gone) (\(Double(gone - 1) * Self.dt) s after the unzoom showed); its fade is \(duration) s")
        #expect(harness.provider.released.isEmpty, "the unzoom released a pane: \(harness.provider.released)")
    }

    /// A second Cmd-Shift-Enter while the dim comes: the dim ends in that key's turn, and the screen never left the grid.
    @Test func aSecondKeyWhileTheDimComesEndsItAtOnce() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let grid = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        #expect(Self.dim(harness) != nil, "two frames after the zoom key no dim shows")
        #expect(grid.isShown(by: Commit.shown(screen)), "two frames after the zoom key the screen left the grid")

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the dim stays after the second key")
        for tick in 1...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            #expect(grid.isShown(by: Commit.shown(screen)), "tick \(tick) shows another layout after the zoom was taken back")
            #expect(Self.dim(harness) == nil, "tick \(tick): a dim shows after the zoom was taken back")
        }
        #expect(!harness.root.advanceFrame(Self.dt), "frames run on after the zoom was taken back")
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }

    /// A screen switch while the dim comes. The dim is in the plane that every screen shares, and no frame steps a
    /// hidden screen, so the switch ends it: the screen the switch shows has no dim over it, and the screen that hid
    /// shows its zoom, with no dim, when the person comes back.
    @Test func aScreenSwitchWhileTheDimComesEndsIt() throws {
        let other = LayoutScreen(id: "t", name: "t", layout: .splits(.leaf("q1")))
        let harness = Commit.Harness(Zoom.screens() + [other], focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.root.screenViews["s"], "SETUP: the shown screen has no view")
        _ = try Self.fade()
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4") + [other])
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.dim(harness) != nil, "SETUP: two frames after the zoom key no dim shows")

        harness.model.selectScreen("t")
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the dim stays over the screen the switch shows")
        for tick in 1...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            #expect(Self.dim(harness) == nil, "tick \(tick): a dim shows over the other screen")
        }
        harness.model.selectScreen("s")
        harness.root.syncWithModel()
        #expect(zoomed.isShown(by: Commit.shown(screen)), "back on its screen the zoomed pane does not show alone: \(Commit.shown(screen).panes)")
        #expect(Self.dim(harness) == nil, "back on its screen the zoom shows under a dim")
    }

    /// The grid with the zoom key just pressed on p4 and two frames stepped: the dim comes over the grid, which the
    /// screen still shows. `zoomed` is the layout the zoom shows at the screen's size of now.
    static func whileTheDimComes() throws -> (harness: Commit.Harness, screen: ScreenContentView, zoomed: @MainActor () -> Commit.Rest) {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        _ = try Self.fade()
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        let zoomed: @MainActor () -> Commit.Rest = { Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style) }
        try #require(Self.dim(harness) != nil && !zoomed().isShown(by: Commit.shown(screen)), "SETUP: two frames after the zoom key the dim does not show over the grid")
        return (harness, screen, zoomed)
    }

    /// Panes stop animating while the dim comes (Reduce Motion turned on, a full-screen transition, a live resize of
    /// the window): the dim's time is counted no more, so the dim ends in the next frame and the zoom shows. It never
    /// waits for a time that nothing counts.
    @Test func whenPanesStopAnimatingWhileTheDimComesTheZoomShows() throws {
        let (harness, screen, zoomed) = try Self.whileTheDimComes()
        defer { harness.window.closeAfterTest() }
        harness.root.context.reduceMotionOverride = true
        var asks = harness.root.advanceFrame(Self.dt)
        #expect(Self.dim(harness) == nil, "the dim stays in the frame after panes stopped animating")
        // The zoom shows in that frame, or in the one after it when its panes hear their sizes only then.
        if !zoomed().isShown(by: Commit.shown(screen)) { asks = harness.root.advanceFrame(Self.dt) }
        #expect(zoomed().isShown(by: Commit.shown(screen)), "two frames after panes stopped animating the zoom does not show: \(Commit.shown(screen).panes)")
        #expect(!asks, "the frame that shows the zoom asks for more frames")
        #expect(!harness.root.advanceFrame(Self.dt) && Self.dim(harness) == nil, "frames run on, or a dim shows, after the zoom showed")
    }

    /// A change of the screen's size while the dim comes (the window's edge moves): the dim was placed for the old
    /// size, so it ends in that turn, and the zoom shows at the new size.
    @Test func aChangeOfTheScreensSizeWhileTheDimComesEndsIt() throws {
        let (harness, screen, zoomed) = try Self.whileTheDimComes()
        defer { harness.window.closeAfterTest() }
        harness.window.setContentSize(NSSize(width: 1400, height: 900))
        harness.root.layoutSubtreeIfNeeded()
        try #require(screen.bounds.size == NSSize(width: 1400, height: 900), "SETUP: the screen did not take the window's new size: \(screen.bounds.size)")
        #expect(Self.dim(harness) == nil, "the dim stays, at its old place, after the screen's size changed")
        // The zoom shows in the next frame, or in the one after it when its panes hear their sizes only then.
        _ = harness.root.advanceFrame(Self.dt)
        if !zoomed().isShown(by: Commit.shown(screen)) { _ = harness.root.advanceFrame(Self.dt) }
        #expect(zoomed().isShown(by: Commit.shown(screen)), "two frames after the size change the zoom does not show at the new size: \(Commit.shown(screen).panes)")
        #expect(Self.dim(harness) == nil, "a dim shows with the zoomed pane")
    }

    /// A page that takes the whole window is a zoom to the layout (`LayoutScreen.presented`), and no zoom of a person:
    /// it comes in its first frame with no dim, and its end brings none.
    @Test func aPageThatTakesTheWholeWindowComesAndGoesWithNoDim() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        _ = try Self.fade()
        var presenting = Zoom.screens(zoomedOn: "p4")
        presenting[0].presented = true
        let (shown, zoomed, _) = try Zoom.frames(of: harness, after: presenting)
        #expect(zoomed.isShown(by: shown[1]) && Self.dim(harness) == nil, "the page did not take its screen in its first frame, or a dim shows: \(shown[1].panes)")
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Zoom.screens())
        let grid = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(grid.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "the page's end did not show the grid in its first frame, or a dim shows over it")
    }

    /// The frame ticks the dim's fade takes: its time in display frames, a whole number of frames counted as that number.
    static func ticks(of fade: TimeInterval) -> Int {
        Int((fade / Self.dt - 1e-6).rounded(.up))
    }

    /// While the dim comes, each pane stays live at the size it shows: the pane that zooms hears its new size only in
    /// the frame where the dim's fade is spent, and the zoom shows after it as any layout change does. A pane that
    /// heard its size in the key's turn kept its old picture, with no new output and no key echo, for the dim's time.
    @Test func whileTheDimComesThePaneThatZoomsHearsNoSize() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let ticks = Self.ticks(of: try Self.fade())
        let surface = try #require(harness.provider.surface("p4"), "SETUP: the pane that zooms has no producer")
        let asked = surface.asks.count

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(surface.asks.count == asked, "the zoom's own turn told the pane that zooms its new size: its picture is held from the key on")
        for tick in 1..<ticks {
            _ = harness.root.advanceFrame(Self.dt)
            #expect(surface.asks.count == asked, "tick \(tick): the pane that zooms heard a size while the dim still comes")
        }
        _ = harness.root.advanceFrame(Self.dt)
        #expect(surface.asks.count == asked + 1, "in the frame where the dim's fade is spent the pane that zooms heard \(surface.asks.count - asked) sizes, not 1")
        #expect(!zoomed.isShown(by: Commit.shown(screen)), "the zoom showed in the frame that told its pane the size, before its producer reported")
        surface.report()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(zoomed.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "the frame after the producer's report does not show the zoom alone with no dim")
    }

    /// A split while the dim comes ends the dim and is a change of its own: it waits for its producers as any change
    /// does, at most 3 frame ticks. The dim's time was no wait for content, so it uses up none of that bound.
    @Test func aSplitWhileTheDimComesWaitsForItsProducers() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        _ = try Self.fade()
        let pair = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.model.apply(screens: Commit.pairZoomed)
        harness.root.syncWithModel()
        for _ in 0..<5 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.dim(harness) != nil && pair.isShown(by: Commit.shown(screen)), "SETUP: five frames after the zoom key the dim does not show over the pair")

        // The pane that was to zoom splits: the zoom is gone, and the split resizes that pane.
        harness.model.apply(screens: Commit.pairSplit(.horizontal))
        let split = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the dim stays after the split")
        #expect(harness.root.advanceFrame(Self.dt), "the split asks for no frame while its producer has not reported")
        #expect(pair.isShown(by: Commit.shown(screen)), "the split showed in its first frame, before its producer reported: the dim's frames used up its wait")
        let left = try #require(harness.provider.surface(Commit.left), "SETUP: the pane that splits has no producer")
        left.report()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(split.isShown(by: Commit.shown(screen)), "the frame after the producer's report does not show the split: \(Commit.shown(screen).panes)")
        #expect(screen.lateSurfaceCommits == 0, "the split counts \(screen.lateSurfaceCommits) late panes")
    }

    /// With no pane animation there is no dim: a zoom and an unzoom each show in their first frame.
    @Test func withNoPaneAnimationAZoomShowsNoDim() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        harness.root.context.reduceMotionOverride = true
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "a dim shows with no pane animation")
        _ = harness.root.advanceFrame(Self.dt)
        #expect(zoomed.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "the zoom did not show in its first frame, or shows a dim")

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(grid.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "the unzoom did not show in its first frame, or shows a dim")
        #expect(!harness.root.advanceFrame(Self.dt), "frames run on with no pane animation")
    }
}
