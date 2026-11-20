import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the divider lines under the pane that an unzoom closes to its place.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. An unzoom brings each divider of
/// its layout back in the frame that shows it, under the pane that still has the screen's size. In a window that
/// gives a pane no ground, a line under that pane shows through it. So no part of a line that shows is inside the
/// rect of that pane, in each frame of the move. The row reads the animations on the layers; it reads no pixels, and
/// it does not read an animation of a line's opacity as a clip.
extension PaneCommitMotionTests {
    /// An unzoom in each kind of window, at each speed at which a pane moves.
    nonisolated static let unzoomLooks: [Look] = windowKinds.flatMap { kind in
        movingSpeeds.map { Look(kind: kind, scene: "unzoom", speed: $0) }
    }

    /// The rect of its screen in which the line of `view` shows when the moves of each act are at `part(act)` of
    /// their way: the line, where the animations on the view's layer put it, cut by that layer when the layer clips
    /// what is in it. Nil: the view is hidden, has the opacity 0, or draws no line now.
    static func lineShowing(_ view: DividerHandleView, at part: (Int) -> CGFloat) -> CGRect? {
        guard !view.isHidden, view.alphaValue > 0, view.isLineVisible, let layer = view.layer, layer.opacity > 0 else { return nil }
        let cell = rect(of: layer, at: part), end = move(of: layer, only: []).end
        let own = origin(of: layer, at: part), still = layer.bounds.origin
        let line = view.lineFrameInSuperview.offsetBy(dx: cell.minX - end.minX - (own.x - still.x), dy: cell.minY - end.minY - (own.y - still.y))
        let shown = layer.masksToBounds ? line.intersection(cell) : line
        return shown.isNull || shown.width <= 0 || shown.height <= 0 ? nil : shown
    }

    /// In the frame that shows an unzoom, in each frame of its move and at rest, no part of a divider's line that
    /// shows is inside the rect of the pane that closes to its place, unless that pane has a ground that covers its
    /// whole rect. Inside is more than 1 pt from the rect's edge: a line in the gap beside the pane's own edge is not
    /// inside the pane. A clip can take more of a line than the rect covers, never less. The row's model has its own
    /// style, the one in which each split draws its line at rest, so the row does not read the app's settings.
    @Test(arguments: unzoomLooks)
    func inAnUnzoomNoDividerLineShowsInsideThePaneThatClosesWithNoGround(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { $0.followsDesignMetrics = false })
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen
        let mover = try #require(Self.movers(of: look.scene, on: screen).first, "SETUP: the unzoom puts no pane over another")
        let layer = try #require(mover.layer, "SETUP: the pane that closes has no layer")
        let lines = screen.dividerViews.values.filter { $0.superview === screen }
        let drawn = lines.filter { Self.lineShowing($0, at: { _ in 1 }) != nil }.count
        try #require(drawn > 0, "SETUP: none of the \(lines.count) dividers on the screen draws a line")
        var faults: [String] = [], bare = 0, under = 0
        let frames = try Self.eachTick(of: look, over) { frame, way, _ in
            let rect = Self.rect(of: layer, at: { _ in way }).insetBy(dx: 1, dy: 1)
            if lines.contains(where: { !$0.isHidden && Self.area($0.lineFrameInSuperview.intersection(rect)) >= 1 }) { under += 1 }
            guard !Self.hasFullGround(mover) else { return }
            if frame != "rest" { bare += 1 }
            var inside: CGFloat = 0, count = 0
            for line in lines {
                guard let shown = Self.lineShowing(line, at: { _ in way }) else { continue }
                let part = Self.area(shown.intersection(rect))
                if part >= 1 { (inside, count) = (inside + part, count + 1) }
            }
            if count > 0 { faults.append("\(frame), inside \(mover.pane) at \(rect): \(count) of \(drawn) lines, \(Int(inside)) pt2") }
        }
        try #require(under > 0, "SETUP: in no frame of the unzoom is the place of a divider's line inside the pane that closes")
        let grounded = look.kind == "still" || look.kind == "opaque"
        try #require(grounded || bare > 0, "SETUP: the pane that closes has a ground in each of the \(frames) frames, in a window of the kind `\(look.kind)`")
        #expect(faults.isEmpty, "\(faults.count) reads show a divider's line inside the pane that an unzoom closes with no ground; the first: \(faults.prefix(3))")
    }
}
