import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a third close key in a move, when the pane that grows in the third close still has a
/// move of the first close: a mask that the third close uses again under ANOTHER pane has only the moves of the
/// motion's cut.
///
/// A mask that the second close made is under the one pane that grew in the second close: the motion's cut
/// (`PaneCommitMotion+Under`) gave its parts the second close's move, for that pane's hole. The third key closes that
/// pane: another pane grows, alone, and the cut uses the mask again for it and adds the third close's move. The move
/// of the second close stays on the parts, so the hole is not at the rect of the pane that grows until that move
/// ends. A copy of a move of the pane that grows (`PaneCommitMotion+Cover`) on such a mask does not mend that: it
/// adds to a hole that is not this pane's hole, and the part of the mask that is inside the pane that grows gets
/// larger.
///
/// This file reads the animations as they are on the layers. It reads no frame of the app and no clock.
extension PaneCommitMotionTests {
    /// One pane on the left; on the right 2 panes side by side above one pane; even split sizes; a hold of the close
    /// key: 3 closes, each in the move of the one before.
    /// - Key 1 closes the pane on the left: the 3 other panes move, so no pane gets a mask.
    /// - Key 2 closes the first pane of the 2 side by side: the second one grows alone, with its move of the first
    ///   close still on its layer. Each of the 2 panes that left gets a mask, and the cut gives the parts of each
    ///   mask the second close's move.
    /// - Key 3 closes the pane that grew: the pane below grows alone, upward, while its move of the first close
    ///   still runs. It is another pane than the one that grew in the second close, and the cut uses the 2 masks
    ///   again for it.
    ///
    /// After the third key, each mask that the second close made has on its parts only the moves that the cut gave
    /// it: the moves of the second close and of the third close. The row reads that from the layers after each key:
    /// in an act, only the cut gives a mask a move with that act's number. A move of another act on a part is a copy
    /// of a move of a pane, on a mask whose hole is not that pane's hole.
    ///
    /// NOT CHECKED, printed: at 3 times of the third close's move, for each of the 2 panes with a mask that is used
    /// again, the width of the widest piece of it that shows inside the rect of the pane that grows, and the area of
    /// all such pieces. Each animation is read at its own time (``keptByOwnTime(_:on:since:)``): the time since the
    /// frame that showed its act. The limit that stays with a mask that 2 acts use makes these numbers; the row puts
    /// no bound on them.
    @Test func afterAThirdCloseKeyAMaskThatIsUsedAgainUnderAnotherPaneHasOnlyTheMovesOfTheCut() throws {
        let top = SplitNode.split(SplitID("top"), axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        let right = SplitNode.split(SplitID("right"), axis: .vertical, ratio: 0.5, a: top, b: .leaf("p3"))
        let screens = Commit.screen(.split(SplitID("all"), axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: right))
        let harness = Commit.Harness(screens, focused: "p0", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        var left: [PaneHostView] = []
        for pane in ["p0", "p1", "p2", "p3"] as [PaneID] {
            let host = try #require(rest[pane], "SETUP: the pane \(pane) does not show at rest")
            left.append(host)
        }
        let below = left.removeLast()

        // One close key on the pane that has the focus, one frame, and the number of the act that it started.
        var acts: [Int] = []
        func key(_ pane: PaneID, _ name: String) throws {
            try #require(harness.model.focusedPane == pane, "SETUP: before the \(name) key the focus is on \(String(describing: harness.model.focusedPane)), not on \(pane)")
            _ = try #require(harness.model.showPaneClose(pane), "SETUP: the model does not show the close of \(pane), the \(name) key")
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
            let act = try #require(Self.acts(on: screen).max(), "SETUP: no pane has a move after the \(name) key")
            try #require(act > (acts.last ?? Int.min), "SETUP: the \(name) key started no act that moves: the acts on the panes are \(Self.acts(on: screen))")
            acts.append(act)
        }
        // The panes of the layout that have a move of `act` on their layers.
        func movers(_ act: Int) -> [PaneHostView] {
            Self.hosts(of: screen).values.filter { host in !host.isLeaving && host.layer.map { !Self.actMoves(act, on: $0).isEmpty } ?? false }
        }

        try key("p0", "first")
        let first = movers(acts[0])
        try #require(first.count == 3, "SETUP: the first close makes \(first.count) panes move, not 3")
        try #require(left.allSatisfy { $0.clipView.layer?.mask == nil }, "SETUP: the first close put a mask on a pane: a mask of the second close is not new")

        try key("p1", "second")
        let second = movers(acts[1])
        try #require(second.count == 1, "SETUP: the second close makes \(second.count) panes move, not 1")
        let grew = second[0]
        try #require(grew === left[2], "SETUP: the pane that grows in the second close is \(grew.pane), not the pane beside the pane of the second close")
        try #require(grew.layer.map { !Self.actMoves(acts[0], on: $0).isEmpty } ?? false,
                     "SETUP: the pane that grows in the second close has no move of the first close on its layer")
        // Each mask that the second close made, and the acts in which the cut gave it a move.
        var masks: [(name: String, host: PaneHostView, mask: PaneHoleMaskLayer, given: Set<Int>)] = []
        for (name, host) in [("first", left[0]), ("second", left[1])] {
            let mask = try #require(host.clipView.layer?.mask as? PaneHoleMaskLayer, "SETUP: the second close put no mask on the clip of the pane of the \(name) close")
            try #require(Self.actsOnParts(of: mask)[acts[1]] != nil, "SETUP: the mask on the pane of the \(name) close has no move of the second close on its parts")
            masks.append((name: name, host: host, mask: mask, given: [acts[1]]))
        }

        try key("p2", "third")
        try #require(left.allSatisfy { $0.isLeaving && !$0.isHidden }, "SETUP: the move does not keep the 3 panes that left")
        let third = movers(acts[2])
        try #require(third.count == 1, "SETUP: the third close makes \(third.count) panes move, not 1")
        try #require(third[0] === below && third[0] !== grew, "SETUP: the pane that grows in the third close is \(third[0].pane), not the pane below")
        let layer = try #require(below.layer, "SETUP: the pane that grows in the third close has no layer")
        try #require(!Self.actMoves(acts[0], on: layer).isEmpty,
                     "SETUP: the pane that grows in the third close has no move of the first close on its layer: the case of this row is not there")
        for index in masks.indices {
            let entry = masks[index]
            try #require(entry.host.clipView.layer?.mask === entry.mask, "SETUP: the third close does not use the mask on the pane of the \(entry.name) close again")
            masks[index].given.insert(acts[2]) // a move with the third close's number is the cut's: a copy has the number of an act before
        }

        var prints: [String] = []
        for entry in masks {
            let onParts = Self.actsOnParts(of: entry.mask).sorted(by: { $0.key < $1.key })
            let others = onParts.filter { !entry.given.contains($0.key) }
            #expect(others.isEmpty, """
                after the third key the mask on the pane of the \(entry.name) close has on its parts \
                \(others.map { "\($0.value) moves of act \($0.key)" }.joined(separator: ", ")). The cut gave this mask a move only in the acts \
                \(entry.given.sorted()): each other move is a copy of a move of a pane, on a mask that the motion uses again under another pane, \
                and it moves a hole that is not that pane's hole
                """)
            prints.append("the mask on the pane of the \(entry.name) close: " + onParts.map { "\($0.value) of act \($0.key)" }.joined(separator: ", "))
        }
        if let mask = left[2].clipView.layer?.mask as? PaneHoleMaskLayer {
            let onParts = Self.actsOnParts(of: mask).sorted(by: { $0.key < $1.key })
            prints.append("the new mask on the pane of the third close: " + onParts.map { "\($0.value) of act \($0.key)" }.joined(separator: ", "))
        }
        // Each close key came one frame after the one before: an animation of the first close is 2 frames older
        // than one of the third close, and one of the second close is 1 frame older.
        var bands: [String] = []
        let firstAct = acts[0], secondAct = acts[1]
        let times: [Double] = [0, Self.close.time / 4, Self.close.time / 2]
        for time in times {
            let since: (Int) -> Double = { act in Double(act == firstAct ? 2 : (act == secondAct ? 1 : 0)) * Self.dt + time }
            let rect = Self.rectByOwnTime(of: layer, since: since)
            var shows: [String] = []
            for entry in masks {
                let kept = Self.keptByOwnTime(entry.host, on: screen, since: since)
                let widths = kept.parts.map { $0.intersection(rect) }.filter { !$0.isNull }.map(\.width)
                let widest = ((widths.max() ?? 0) * 10).rounded() / 10
                shows.append("the pane of the \(entry.name) close: the widest piece \(widest) pt, the area \(Int(kept.area(in: rect).rounded())) pt2")
            }
            bands.append("\((time * 1000).rounded() / 1000) s after the frame of the third key, inside \(below.pane) at \(rect): \(shows.joined(separator: ", "))")
        }
        // A pane with a mask can have animations on its own layer too: the read of the pieces counts them as moves.
        var own: [String] = []
        for entry in masks {
            let onOwn = Set((entry.host.layer?.animationKeys() ?? []).compactMap { Self.act(of: $0) }).sorted()
            own.append("the pane of the \(entry.name) close: \(onOwn)")
        }
        let onLayer = Self.acts(on: screen).filter { !Self.actMoves($0, on: layer).isEmpty }
        print("ROW (USED AGAIN): the acts of the 3 close keys: \(acts); the pane that grew in the second close: \(grew.pane);",
              "the pane that grows in the third close: \(below.pane), with moves of the acts \(onLayer) on its layer;",
              "the moves on the parts of each mask after the third key: \(prints.joined(separator: "; ")).",
              "NOT CHECKED: what shows of each pane with a mask that is used again, inside the pane that grows, at 3 times: \(bands.joined(separator: "; "));",
              "the acts with an animation on the own layer of each of those panes: \(own.joined(separator: ", "))")
    }
}
