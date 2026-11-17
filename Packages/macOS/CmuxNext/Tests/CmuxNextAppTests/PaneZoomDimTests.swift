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

    /// What is wrong with where the dim is, against the panes as they show: it must leave `pane` clear and cover the
    /// middle of each of `others`.
    static func misses(_ dim: (view: NSView, layer: CALayer), clear pane: PaneID, over others: [PaneID], in harness: Commit.Harness) throws -> [String] {
        let root = harness.root
        let parts = (dim.layer.sublayers ?? []).map { $0.frame.offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY) }
        let host = try #require(root.context.hosts[pane], "\(pane) has no host")
        let hole = root.convert(host.contentRect, from: host)
        var found: [String] = []
        for part in parts where part.intersects(hole.insetBy(dx: 1, dy: 1)) { found.append("the dim covers \(pane) at \(part)") }
        for other in others {
            let shown = try #require(root.context.hosts[other], "\(other) has no host")
            let frame = root.convert(shown.bounds, from: shown)
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            if !parts.contains(where: { $0.contains(middle) }) { found.append("the dim does not cover \(other)") }
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

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        // The key's own turn: nothing moved, and the dim comes over the other panes.
        #expect(grid.isShown(by: Commit.shown(screen)), "the zoom's own turn changed what the screen shows")
        let dim = try #require(Self.dim(harness), "the zoom's own turn shows no dim over the other panes")
        #expect(dim.layer.opacity > 0.05 && dim.layer.opacity < 0.9, "the dim's strength is \(dim.layer.opacity)")
        let off = try Self.misses(dim, clear: "p4", over: ["p1", "p2", "p3"], in: harness)
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
        let off = try Self.misses(dim, clear: "p4", over: ["p1", "p2", "p3"], in: harness)
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
