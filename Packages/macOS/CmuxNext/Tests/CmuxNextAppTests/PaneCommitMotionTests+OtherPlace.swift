import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second close in another place of the window, in a close's move.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A close makes one pane grow over
/// the pane that it took out, and that pane still shows under it until the motion's end. A second close in the move,
/// of a pane in another place, makes another pane grow there, and the first pane that grows is still on its way. The
/// rule is for that first pane too: no pane under it shows inside it, in each frame, in a window that gives it no
/// ground.
extension PaneCommitMotionTests {
    /// The 2 closes in a window that gives a pane no ground (`glass`) and in one that gives it a ground (`opaque`),
    /// at each speed at which a pane moves.
    nonisolated static let otherPlaceLooks: [Look] = ["glass", "opaque"].flatMap { kind in
        movingSpeeds.map { Look(kind: kind, scene: "close", speed: $0) }
    }

    /// The pane of the second close, of 6 panes in halves: it is in the other half of the window, and the pane
    /// beside it takes its room.
    nonisolated static let closedInAnotherPlace = "pb"

    /// A close of the first of 6 panes, and in its move the close of a pane in the other half of the window. One
    /// pane takes the room of each. The pane that grows first is still on its way when the second close shows, and
    /// the pane that the second close makes grow does not go over the place of the first close's pane. In each frame
    /// from the one that shows the second close to the motion's end:
    /// 1. No part of another pane that shows is inside the rect of the pane that grows first, unless that pane has a
    ///    ground that covers its whole rect: it then covers what is under it.
    ///
    /// This is the rule, and not a record of what the code does: the row is red in a window in which the rule does
    /// not hold. The window with a ground is the control. There the pane that grows first covers what is under it,
    /// and the row prints what it covers of the first close's pane.
    ///
    /// The row prints, for each case: the frames read; the frames in which the pane that grows first is not at its
    /// place; the frames in which the first close's pane shows inside it by its own layers, in 1 pt2 or more; the
    /// largest such part, in pt2 and as a part of the rect of the pane that grows first in that frame; the frames
    /// in which that pane has a ground. Each layer and each part of a mask is read at its own animations' time
    /// (`PaneCommitMotionTests+OwnTime`). A window on a pane's own layer is not read.
    @Test(arguments: otherPlaceLooks)
    func aCloseInAnotherPlaceInAClosesMoveShowsNoPaneInsideThePaneThatStillGrows(_ look: Look) throws {
        let over = try Self.overPicture("close", panes: 6, gap: look.gap, speed: look.speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let grown = Self.movers(of: "close", on: screen)
        try #require(grown.count == 1, "SETUP: the first close makes \(grown.count) panes grow, not 1")
        let grower = grown[0], layer = try #require(grower.layer, "SETUP: the pane that grows first has no layer")
        let gone = try #require(Self.paneHosts(screen).first { $0.isLeaving && !$0.isHidden }, "SETUP: the first close keeps no pane under the pane that takes its room")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the first close")
        let first = motion.serial
        let name = Self.closedInAnotherPlace
        let found = Self.paneHosts(screen).first { host in host !== grower && !host.isLeaving && !host.isHidden && host.pane == PaneID(name) }
        let second = try #require(found, "SETUP: the screen shows no other pane `\(name)` in the first close's move")

        _ = try #require(harness.model.showPaneClose(second.pane), "SETUP: the model does not show the close of \(second.pane)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close of \(second.pane) in the first close's move shows in one frame: no second act moves")
        try #require(gone.isLeaving && !gone.isHidden, "SETUP: \(gone.pane), the pane of the first close, does not show after the close of \(second.pane)")
        try #require(Self.moves(grower), "SETUP: \(grower.pane), the pane that grows first, has no move after the close of \(second.pane)")
        let grows = Self.movers(of: "close", on: screen).filter { $0 !== grower }
        try #require(grows.count == 1, "SETUP: the second close makes \(grows.count) panes grow, not 1")
        let next = grows[0]
        try #require(Self.area(gone.frame.intersection(next.frame)) < 1, "SETUP: \(next.pane), the pane that the second close makes grow, goes over the place of \(gone.pane)")
        let grounded = look.kind == "opaque", has = Self.hasFullGround(grower)
        try #require(has == grounded, "SETUP: in a window of the kind `\(look.kind)`, has the pane that grows first a ground that covers its rect: \(has)")
        var faults: [String] = []
        var under = 0, away = 0, wide = 0, onTheWay = 0, covered = 0, tick = 0, most: CGFloat = 0, share: CGFloat = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let since: (Int) -> Double = { act in Double(act == first ? Self.framesBeforeTheKey + 1 + now : now) * Self.dt }
            let rect = Self.rectByOwnTime(of: layer, since: since), rest = grower.frame
            let moving = abs(rect.minX - rest.minX) > 0.5 || abs(rect.minY - rest.minY) > 0.5
                || abs(rect.width - rest.width) > 0.5 || abs(rect.height - rest.height) > 0.5
            if moving { away += 1 }
            if Self.area(gone.frame.intersection(rect)) >= 1 { under += 1 }
            let covers = Self.hasFullGround(grower)
            if covers { covered += 1 }
            var shows: [String] = []
            for other in Self.paneHosts(screen) where other !== grower && !other.isHidden {
                let shown = Self.keptByOwnTime(other, on: screen, since: since).area(in: rect)
                guard shown >= 1 else { continue }
                if other === gone {
                    wide += 1
                    if moving { onTheWay += 1 }
                    if shown > most { (most, share) = (shown, shown / max(Self.area(rect), 1)) }
                }
                if !covers { shows.append("\(other.pane) in \(Int(shown)) pt2") }
            }
            if !shows.isEmpty { faults.append("tick \(tick), inside \(grower.pane) at \(rect): \(shows.joined(separator: ", "))") }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the close of \(second.pane)")
        try #require(under > 0, "SETUP: in no frame after the second close is the place of \(gone.pane) under the pane that grows first")
        try #require(away > 0, "SETUP: \(grower.pane), the pane that grows first, is at its place in each frame after the second close")
        print("ROW (FAR CLOSE IN A CLOSE): \(look.kind), \(look.speed), the close of \(second.pane) in the close of \(gone.pane): \(grower.pane) grows first,",
              "\(next.pane) grows second; frames read: \(tick); frames with \(grower.pane) not at its place: \(away); frames in which \(gone.pane) shows",
              "by its own layers inside \(grower.pane) in 1 pt2 or more: \(wide), of them with \(grower.pane) not at its place: \(onTheWay); the largest part:",
              "\(Int(most.rounded())) pt2 = \((share * 1000).rounded() / 1000) of the rect of \(grower.pane) in that frame; frames in which \(grower.pane)",
              "has a ground that covers its rect: \(covered); frames in which a pane shows inside \(grower.pane) with no ground over it: \(faults.count)")
        #expect(faults.isEmpty,
                "(1) in \(faults.count) frames after the close of \(second.pane) another pane shows inside \(grower.pane), the pane that grows first, with no ground; the first: \(faults.prefix(3))")
    }
}
