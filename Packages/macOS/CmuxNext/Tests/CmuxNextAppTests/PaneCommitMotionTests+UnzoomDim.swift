import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the value of an unzoom's dim.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. An unzoom shows the other panes
/// under a dim that goes. The dim's layer keeps its strength as its own value, and one fade takes it to nothing and
/// holds that end: a layer that loses its fade then shows the dim, not a frame with no dim at all. So the view has
/// to leave: after the move's end no dim view is in the overlay plane, at each kind of end. The rows read the layer's
/// own value, the animations on it and where the view is; they read no pixels.
extension PaneCommitMotionTests {
    /// The ends of an unzoom's move after which no dim may be left.
    nonisolated static let dimEnds = ["plain", "the key again", "a close in the move"]

    /// The fades of the opacity of `layer`.
    static func fades(on layer: CALayer) -> [CABasicAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }.filter { $0.keyPath == "opacity" }
    }

    /// In the frame that shows an unzoom, in an opaque and in a glass window: the dim's layer has its strength as
    /// its own value, and one fade of its opacity, from that strength to nothing, which holds its end.
    @Test(arguments: movingSpeeds, ["opaque", "glass"])
    func inTheFrameThatShowsAnUnzoomTheDimsOwnValueIsItsStrength(_ speed: MotionSpeed, _ kind: String) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: kind, speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(kind, of: over)
        try #require(Self.inFlight(over.screen), "SETUP: no pane moves in the frame that shows the unzoom")
        let dim = try #require(Dim.dim(over.harness), "SETUP: the frame that shows the unzoom shows no dim")
        try #require(dim.view.window != nil, "SETUP: the dim's view is in no window")
        let fades = Self.fades(on: dim.layer)
        try #require(fades.count == 1, "the dim's layer has \(fades.count) fades of its opacity, not one")
        let fade = fades[0]
        let from = try #require((fade.fromValue as? NSNumber)?.floatValue, "the dim's fade names no start")
        let to = (fade.toValue as? NSNumber)?.floatValue
        try #require(from > 0.05, "SETUP: the dim's fade starts at \(from)")
        print("DIM ROW: unzoom, \(kind), \(speed.rawValue): the dim layer's own value is \(dim.layer.opacity); its one fade goes from \(from) to "
            + "\(to.map { "\($0)" } ?? "no value") over \(fade.duration) s, fill mode \(fade.fillMode.rawValue), removed at its end: \(fade.isRemovedOnCompletion)")
        #expect(dim.layer.opacity == from,
                "the dim layer's own value is \(dim.layer.opacity), not the strength \(from): a layer that loses its fade shows no dim")
        #expect(to == 0, "the dim's fade does not end at nothing: \(String(describing: fade.toValue))")
        #expect(fade.fillMode == .forwards && !fade.isRemovedOnCompletion,
                "the dim's fade does not hold its end: after it the layer's own value \(dim.layer.opacity) shows")
    }

    /// After the end of an unzoom's move in a glass window, at each kind of end (``dimEnds``): no dim view is in the
    /// overlay plane, the view that the unzoom showed is in no window, and the dim asks for no frame. The key again
    /// is a zoom in the unzoom's move: the row then reads the zoomed screen at rest.
    @Test(arguments: dimEnds, movingSpeeds)
    func afterAnUnzoomsMoveNoDimIsLeft(_ end: String, _ speed: MotionSpeed) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        let dim = try #require(Dim.dim(harness), "SETUP: the frame that shows the unzoom shows no dim")
        try #require(dim.view.window != nil, "SETUP: the dim's view is in no window")
        let first = motion.serial
        if end != "plain" {
            for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
            try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
            try #require(Dim.dim(harness)?.view === dim.view, "SETUP: \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom its dim is gone")
        }
        switch end {
        case "the key again":
            try Self.secondAct(on: over, zoomed: mover.pane, of: 6, closing: nil)
            try #require(motion.serial == first + 1, "SETUP: the zoom in the unzoom's move shows in one frame: no second act moves")
        case "a close in the move":
            _ = try #require(harness.model.showPaneClose(PaneID("pbab")), "SETUP: the model does not show the close of a pane")
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
            try #require(motion.serial == first + 1, "SETUP: the close in the unzoom's move shows in one frame: no second act moves")
        default:
            break
        }
        var tick = 0
        while Self.inFlight(screen) || screen.zoomDim.goes, tick < 2 * Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the last act (`\(end)`)")
        let left = Dim.dim(harness)
        print("DIM ROW: the end `\(end)`, \(speed.rawValue): \(tick) frames after the last act a dim view is in the overlay plane: \(left != nil); "
            + "the unzoom's dim view is in a window: \(dim.view.window != nil); the dim asks for frames: \(screen.zoomDim.goes)")
        #expect(left == nil, "after the end (`\(end)`) a dim view is in the overlay plane; its layer's own value is \(left?.layer.opacity ?? -1)")
        #expect(dim.view.superview == nil && dim.view.window == nil, "after the end (`\(end)`) the dim view of the unzoom is still in a view or a window")
        #expect(screen.zoomDim.phase == .off && !screen.zoomDim.goes, "after the end (`\(end)`) the dim still counts its time and asks for frames")
    }
}
