import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, an unzoom (Cmd-Shift-Enter on a zoomed pane): the pane that had the screen closes to
/// its place over the panes that come back.
///
/// The unzoom shows as any change does: the first display frame after the key has every pane at its place as its
/// model. In that frame the pane that had the screen starts its move from the screen's size, above the others, and
/// its last frame shows in its host at the size it had, so the room that the moving clip still has shows what the
/// pane showed there. The frame that ends the motion takes the last frame away. A second act in the motion takes it
/// away in the frame that shows that act. A pane that gives no last frame unzooms in one frame, as with the motion
/// off.
extension PaneCommitMotionTests {
    /// Where an unzoom's spring animation ends, with 0.2 percent of its way left.
    nonisolated static let unzoom = Act(name: "unzoom", time: 0.203)

    /// A pane content that rides and gives its last frame, in a content area of the double's view.
    final class Picture: NSView, PaneCommitMotionRiding, PaneCommitMotionLastFrameGiving {
        /// The view's size at each time the motion asked for its last frame.
        var asked: [CGSize] = []
        let pixels = NSImage(size: NSSize(width: 8, height: 8))
        var paneCommitMotionLastFrame: PaneCommitMotionLastFrame? {
            asked.append(bounds.size)
            return PaneCommitMotionLastFrame(contents: pixels, gravity: .topLeft, scale: 1, rect: bounds)
        }
    }

    /// An unzoom of p4 of the 2 by 2 grid, with the key's turn done and `frames` display frames stepped.
    struct Unzooming {
        let zoom: Zooming
        let host: PaneHostView
        let picture: Picture
        /// While p4 had the screen: its host layer's frame, where its picture showed in its host, and its content
        /// rect in the layout root's coordinates.
        let whole: CGRect
        let shown: CGRect
        let hole: CGRect
    }

    /// `picture`: p4's content gives its last frame. `moves`: the panes' move is on at the unzoom.
    static func unzooming(frames: Int, picture gives: Bool = true, moves: Bool = true) throws -> Unzooming {
        let zoom = try zooming(frames: 0)
        var begun = false
        defer { if !begun { zoom.harness.window.closeAfterTest() } }
        let harness = zoom.harness
        Commit.rest(harness)
        try #require(restsZoomed(zoom), "SETUP: the zoom did not come to rest with no dim")
        let host = try #require(harness.root.context.hosts["p4"], "SETUP: the zoomed pane has no host")
        let content = try #require(harness.provider.contents["p4"], "SETUP: the zoomed pane has no content")
        let picture = Picture(frame: content.bounds)
        if gives {
            let area = PaneContentAreaView(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            picture.autoresizingMask = [.width, .height]
            area.addSubview(picture)
            content.addSubview(area)
        }
        if !moves { harness.root.context.commitMotionOverride = false }
        let whole = try #require(host.layer?.frame)
        let shown = host.convert(content.bounds, from: content)
        let hole = harness.root.convert(host.contentRect, from: host)
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        for _ in 0..<frames { _ = harness.root.advanceFrame(dt) }
        begun = true
        return Unzooming(zoom: zoom, host: host, picture: picture, whole: whole, shown: shown, hole: hole)
    }

    /// The views that show a pane's last frame on `screen` now.
    static func lastFrames(on screen: ScreenContentView) -> [NSView] {
        screen.subviews.flatMap(\.subviews).filter { $0.identifier?.rawValue == PaneCommitMotion.lastFrameName }
    }

    /// The first frame after the unzoom key has the grid as its model. The pane that had the screen has a move from
    /// the screen's size, above the other panes, which have none. Its last frame shows in its host where it showed,
    /// at its old size, with no animation on it, in each frame of the motion. The motion asked for it one time,
    /// before the pane's content heard its new size. The dim never covers the pane that closes. The frame that ends
    /// the motion has no last frame, in the unzoom's time; then the dim goes and the frames stop.
    @Test func anUnzoomClosesItsPaneOverTheOthersUnderItsLastFrame() throws {
        let unzoom = try Self.unzooming(frames: 0)
        let zoom = unzoom.zoom, harness = zoom.harness, screen = zoom.screen, host = unzoom.host
        defer { harness.window.closeAfterTest() }
        #expect(Self.lastFrames(on: screen).isEmpty && !Self.inFlight(screen), "the unzoom key's own turn put a last frame or a move on the screen")

        let asks = harness.root.advanceFrame(Self.dt)
        #expect(zoom.grid.isShown(by: Commit.shown(screen)), "the first frame after the unzoom key does not show the grid: \(Commit.shown(screen).panes)")
        let layer = try #require(host.layer)
        let move = Self.move(of: layer)
        #expect(move.moves && Commit.near(move.start, unzoom.whole), "the pane that had the screen has no move from the screen's size: \(move.start), \(unzoom.whole)")
        #expect(move.issues.isEmpty && move.animations.allSatisfy(Self.hasNoBounce), "the pane's move is no move of a clip on a spring that does not pass its end: \(move.issues)")
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            let other = try #require(harness.root.context.hosts[pane]?.layer, "\(pane) has no host in the frame that shows the unzoom")
            #expect(!Self.move(of: other).moves, "\(pane) has a move on its layer: the panes that come back show at their places")
            #expect(other.zPosition < layer.zPosition, "\(pane) is not under the pane that closes over it")
        }
        #expect(asks, "the frame that begins the unzoom's move asks for no frame")

        let small = try #require(zoom.grid.panes["p4"])
        let was = try #require(unzoom.picture.asked.first, "the motion did not ask the pane's content for its last frame")
        #expect(unzoom.picture.asked.count == 1, "the motion asked for the last frame \(unzoom.picture.asked.count) times")
        #expect(was.width > small.width + 1 && was.height > small.height + 1, "the motion asked for the last frame after the content heard its new size: \(was)")
        let last = try #require(Self.lastFrames(on: screen).first, "the frame that begins the unzoom's move shows no last frame")
        #expect(Self.lastFrames(on: screen).count == 1 && last.superview === host, "the last frame is not one view in its pane's host")
        #expect(last.layer?.contents != nil && (last.layer?.animationKeys() ?? []).isEmpty, "the last frame has no picture, or an animation scales or moves it")

        let dim = try #require(Dim.dim(harness), "the frame that shows the unzoom shows no dim over the other panes")
        let parts = (dim.layer.sublayers ?? []).map { Self.move(of: $0) }
        let hole = Move(start: unzoom.hole, end: harness.root.convert(host.contentRect, from: host))
        for part in [0, 0.5, 1] as [CGFloat] {
            let clear = hole.rect(at: part).insetBy(dx: 1, dy: 1)
            for piece in parts {
                let cut = piece.rect(at: part).offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY).intersection(clear)
                #expect(cut.isNull || cut.width < 0.5 || cut.height < 0.5, "at \(part) of the move the dim covers the pane that closes: \(cut)")
            }
        }

        var ticks = 0
        while Self.inFlight(screen), ticks < Commit.frames {
            #expect(Self.lastFrames(on: screen).first === last && Commit.near(last.frame, unzoom.shown),
                    "frame \(ticks + 1) of the motion does not show the last frame where the pane showed it: \(last.frame), \(unzoom.shown)")
            #expect(zoom.grid.isShown(by: Commit.shown(screen)), "frame \(ticks + 1) of the motion shows another layout than the grid")
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        #expect(Double(ticks) * Self.dt <= Self.unzoom.time + 2 * Self.dt,
                "the unzoom's motion ended \(Double(ticks) * Self.dt) s after the frame that began it; an unzoom's time is \(Self.unzoom.time) s")
        #expect(Self.lastFrames(on: screen).isEmpty && last.superview == nil, "the frame that ends the motion still shows the pane's last frame")
        #expect(layer.zPosition == 0, "after the motion's end the pane's layer is still above the others: \(layer.zPosition)")
        #expect(unzoom.picture.asked.count == 1, "the motion asked for the last frame on a frame: \(unzoom.picture.asked.count) times")
        var runs = true
        for _ in 0..<Commit.frames { runs = harness.root.advanceFrame(Self.dt) }
        #expect(zoom.grid.isShown(by: Commit.shown(screen)) && !runs && Dim.dim(harness) == nil,
                "\(Commit.frames) frames after the motion's end the grid does not rest with no dim")
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }

    /// A second act in the unzoom's motion (the zoom key again, or a close of the pane that closes): the frame that
    /// shows that act has no last frame, so no old picture shows over a new layout, and the motion asks for no new
    /// one. When the frames stop the screen shows the act's layout alone, and the pane's layer is not above the others.
    @Test(arguments: ["zoom again", "close"])
    func aSecondActInAnUnzoomsMotionTakesTheLastFrameAway(_ act: String) throws {
        let unzoom = try Self.unzooming(frames: 3)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        try #require(Self.inFlight(screen) && Self.lastFrames(on: screen).count == 1, "SETUP: three frames after the unzoom key its pane does not move under its last frame")
        // The grid less p4: p3 takes the whole right half.
        let stays: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), b: .leaf("p3"))
        harness.model.apply(screens: act == "close" ? Commit.screen(stays) : Zoom.screens(zoomedOn: "p4"))
        let after = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let left = unzoom.host.subviews.filter { $0.identifier?.rawValue == PaneCommitMotion.lastFrameName }
        #expect(Self.lastFrames(on: screen).isEmpty && left.isEmpty, "the frame that shows the second act still shows the pane's old picture")
        #expect(Self.places(after, on: screen), "the frame that shows the second act does not have its panes at their places: \(Self.hosts(of: screen).mapValues(\.frame))")
        for _ in 0..<Commit.frames { _ = harness.root.advanceFrame(Self.dt) }
        #expect(after.isShown(by: Commit.shown(screen)) && !Self.inFlight(screen), "\(Commit.frames) frames after the second act the screen does not show its layout alone, at rest")
        #expect((unzoom.host.layer?.zPosition ?? 0) == 0, "after the motion's end the pane's layer is not at its own height: \(String(describing: unzoom.host.layer?.zPosition))")
        #expect(unzoom.picture.asked.count == 1, "the motion asked for a last frame \(unzoom.picture.asked.count) times")
    }

    /// With the panes' move off, and for a pane whose content gives no last frame, an unzoom shows in one frame as
    /// it did before: the grid, no move, no last frame, and the dim over the other panes.
    @Test(arguments: ["the move is off", "no last frame"])
    func anUnzoomThatCanNotCloseItsPaneShowsInOneFrame(_ why: String) throws {
        let unzoom = try Self.unzooming(frames: 1, picture: why == "the move is off", moves: why != "the move is off")
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        #expect(unzoom.zoom.grid.isShown(by: Commit.shown(screen)), "the first frame after the unzoom key does not show the grid: \(Commit.shown(screen).panes)")
        #expect(!Self.inFlight(screen) && Self.lastFrames(on: screen).isEmpty, "a pane moves, or a last frame shows")
        #expect(unzoom.picture.asked.isEmpty, "the motion asked for a last frame that it does not show")
        #expect((unzoom.host.layer?.zPosition ?? 0) == 0, "the pane's layer is above the others with no move")
        #expect(Dim.dim(harness) != nil, "the frame that shows the unzoom shows no dim over the other panes")
    }
}
