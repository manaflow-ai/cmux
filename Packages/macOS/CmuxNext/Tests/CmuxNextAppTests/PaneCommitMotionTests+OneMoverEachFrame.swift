import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the panes under ONE pane that moves, in each frame of its move.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. An act that moves one pane puts a
/// mask with a hole on the clip of each pane under it, in each kind of window (`PaneCommitMotion+Under`). The 2 rows
/// of `PaneCommitMotionTests+Under` read a zoom and an unzoom at 3 parts of the move in one kind of window; this row
/// adds each frame, a window with a ground against one with none, and a close in which one pane takes the room.
extension PaneCommitMotionTests {
    /// A zoom and an unzoom at each speed at which a pane moves, and one close, in a glass and in an opaque window.
    nonisolated static let oneMoverLooks: [Look] = {
        var looks: [Look] = []
        for kind in ["glass", "opaque"] {
            for scene in ["zoom", "unzoom"] {
                for speed in movingSpeeds { looks.append(Look(kind: kind, scene: scene, speed: speed)) }
            }
            looks.append(Look(kind: kind, scene: "close", speed: .fast))
        }
        return looks
    }()

    /// A zoom, an unzoom and a close of 6 panes that move one pane. In the frame that shows the act and in each frame
    /// of the move, each other pane that shows is read by its clip and the mask on that clip alone (no ground of
    /// the pane over it counts): less than 1 pt2 of it is inside the rect of the pane that moves, and it shows in
    /// each part of its place outside that rect. No such pane has an animation of the motion on its own layer: the
    /// mask does the work. At the motion's end no pane has a mask on its clip, and the motion keeps none.
    @Test(arguments: oneMoverLooks)
    func inEachFrameEachPaneUnderTheOnePaneThatMovesShowsOnlyOutsideIt(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, motion = screen.zoomDim.motion
        let movers = Self.movers(of: look.scene, on: screen)
        try #require(movers.count == 1, "SETUP: the \(look.scene) moves \(movers.count) panes over the others, not 1")
        let mover = movers[0], layer = try #require(mover.layer, "SETUP: the pane that moves has no layer")
        let others = Self.paneHosts(screen).filter { $0 !== mover }
        var faults: [String] = [], under = 0
        try Self.eachTick(of: look, over) { frame, way, _ in
            let rect = Self.rect(of: layer) { _ in way }
            for other in others where !other.isHidden && other.alphaValue > 0 {
                if frame != "rest", Self.area(other.frame.intersection(rect)) >= 1 { under += 1 }
                let own = Self.commitKeys(on: other)
                if !own.isEmpty { faults.append("\(frame), \(other.pane): its own layer has the animations \(own)") }
                let seen = Self.kept(other, on: screen, over: [], at: way)
                let inside = seen.area(in: rect), outside = seen.area(in: seen.shows) - inside
                let room = Self.area(seen.shows) - Self.area(seen.shows.intersection(rect))
                if inside >= 1 { faults.append("\(frame), \(other.pane): \(Int(inside)) pt2 of it show inside \(mover.pane) at \(rect)") }
                if outside < room - 1 { faults.append("\(frame), \(other.pane): it shows in \(Int(outside)) pt2 of the \(Int(room)) pt2 of its place outside \(mover.pane)") }
            }
        }
        try #require(under > 0, "SETUP: in no frame of the \(look.scene) is the place of another pane under the pane that moves")
        #expect(faults.isEmpty, "\(faults.count) reads of a pane under the one pane that moves are wrong; the first: \(faults.prefix(3))")
        let masks = Self.paneHosts(screen).filter { $0.clipView.layer?.mask != nil }.map(\.pane)
        #expect(masks.isEmpty && motion.cuts.isEmpty, "at the motion's end the panes \(masks) have a mask on their clip; the motion keeps \(motion.cuts.count)")
    }
}
