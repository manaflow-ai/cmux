import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The light around a zoom (Cmd-Shift-Enter): the other panes dim, and no frame shows a pane between two layouts.
///
/// - A zoom shows as any layout change does, in the first frame after its key. A dim comes only with the move of the
///   pane that zooms, in that frame (`PaneCommitMotionTests+Zoom` holds those rows: the dim with the move, a second
///   key, a screen switch, a change of the screen's size, panes that stop animating, a split and a close of the pane
///   that zooms, and the sizes that pane hears). This suite's fixture asks for no move: a zoom shows here with no dim.
/// - An unzoom shows every pane at its place in one frame, the other panes under the dim, which then fades out.
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
        try #require(duration > 0 && duration <= PaneZoomDim.longest, "SETUP: the pane veil's fade is \(duration) s on this Mac")
        return duration
    }

    /// The display frame after a zoom key that shows the zoom on `screen`: the first one. No frame waits for a dim:
    /// a zoom's dim comes with the move of its pane, in the frame that shows the zoom.
    static func showFrame(of screen: ScreenContentView) -> Int { 1 }

    /// A zoom whose pane does not move (this fixture asks for no move of its panes) shows as any layout change does:
    /// the key's own turn changes nothing on the screen and brings no dim, the first frame after it shows the zoomed
    /// pane alone with no dim, and no frame is asked for after it. No frame waits for a dim.
    @Test func aZoomWhosePaneDoesNotMoveShowsInItsFirstFrameWithNoDim() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        // Without these two the row proves nothing: a dim can fade here, and the panes' move is off.
        _ = try Self.fade()
        try #require(screen.zoomDim.fade(on: screen) > 0 && !harness.root.context.movesPanesAtCommit, "SETUP: no dim can fade here, or the panes' move is on")
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        #expect(grid.isShown(by: Commit.shown(screen)), "the zoom's own turn changed what the screen shows")
        #expect(Self.dim(harness) == nil, "the zoom's own turn shows a dim: a dim comes only with the move of the pane that zooms")
        let asks = harness.root.advanceFrame(Self.dt)
        let frame = Commit.shown(screen)
        #expect(zoomed.isShown(by: frame), "the first frame after the zoom key does not show the zoomed pane alone: \(frame.panes)")
        #expect(frame.misfits.isEmpty, "the frame that shows the zoom: a pane's content is not at the rect its pane gives it: \(frame.misfits)")
        #expect(Self.dim(harness) == nil, "the frame that shows a zoom with no move shows a dim")
        #expect(!asks || !harness.root.advanceFrame(Self.dt), "frames run on after a zoom that showed in one frame")
        #expect(harness.provider.released.isEmpty, "the zoom released a pane: \(harness.provider.released)")
    }

    @Test func anUnzoomShowsEveryPaneUnderADimThatFades() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let fade = try Self.fade()
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
        #expect(((going.fromValue as? Float) ?? 0) > 0.05, "the dim's fade is not from its strength: from \(String(describing: going.fromValue))")
        #expect(going.duration == fade, "the dim's fade on its layer is over \(going.duration) s, not the pane veil's \(fade) s")
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
        #expect(Double(gone) * Self.dt <= 0.3 && abs(Double(gone - 1) * Self.dt - fade) <= Self.dt + 1e-6,
                "the dim went at tick \(gone) (\(Double(gone - 1) * Self.dt) s after the unzoom showed); its fade is \(fade) s")
        #expect(harness.provider.released.isEmpty, "the unzoom released a pane: \(harness.provider.released)")
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
