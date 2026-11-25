import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a third close key in a move: a mask that the third close uses again under ANOTHER pane
/// has no copy of a move of the pane that grew in the second close.
///
/// The one pane that grows in the second close has its move of the first close on its layer: each mask that the
/// second close makes gets a copy of that move on its parts (`PaneCommitMotion+Cover`), so that its hole goes with
/// that pane. The third key closes that pane: another pane grows, alone, and the motion uses the masks again for it
/// (`PaneCommitMotion+Under`). A copy that stays on such a mask moves the hole by a move that the pane over it does
/// not have: a part of the mask is then on the pane that grows.
///
/// This file reads the animations as they are on the layers. It reads no frame of the app and no clock.
extension PaneCommitMotionTests {
    /// The acts whose moves of a position or of a size are on the parts of `mask` now, each with the count of
    /// those moves.
    static func actsOnParts(of mask: CALayer) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for part in mask.sublayers ?? [] {
            for key in part.animationKeys() ?? [] {
                guard let act = Self.act(of: key), let animation = part.animation(forKey: key) as? CABasicAnimation,
                      animation.keyPath == "position" || animation.keyPath == "bounds.size" else { continue }
                counts[act, default: 0] += 1
            }
        }
        return counts
    }

    /// 3 panes side by side with even split sizes, above one pane, and a hold of the close key: 3 closes, each in
    /// the move of the one before.
    /// - Key 1 closes the middle pane of the 3: the 2 panes beside it move, so no pane gets a mask.
    /// - Key 2 closes the first pane, which has the focus: the last pane grows alone, with its move of the first
    ///   close still on its layer. Each of the 2 panes that left gets a mask, and the parts of each mask get the
    ///   second close's move and a copy of the first close's move.
    /// - Key 3 closes the last pane, which has the focus: the pane below grows alone, from rest. It is another pane
    ///   than the one that grew in the second close, and the motion uses the 2 masks again for it.
    ///
    /// After the third key, each move on a part of each mask is a move of this act's hole. For each act with a move
    /// on a part: the pane that grows in the third close has its own move of that act on its layer, or the mask got
    /// its move of that act in that act. The row reads the second from the layers after each key: in an act, only
    /// the motion's cut gives a mask a move with that act's number. A move of another act on a part is a copy of a
    /// move of a pane that does not move in this act.
    @Test func afterAThirdCloseKeyNoMaskKeepsACopyOfAMoveOfAPaneThatDoesNotMoveInThisAct() throws {
        let three = SplitNode.split(SplitID("pair"), axis: .horizontal, ratio: 2.0 / 3,
                                    a: .split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1")), b: .leaf("p2"))
        let screens = Commit.screen(.split(SplitID("all"), axis: .vertical, ratio: 0.5, a: three, b: .leaf("p3")))
        let harness = Commit.Harness(screens, focused: "p1", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        var left: [PaneHostView] = []
        for pane in ["p1", "p0", "p2", "p3"] as [PaneID] {
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

        try key("p1", "first")
        try #require(left.allSatisfy { $0.clipView.layer?.mask == nil }, "SETUP: the first close put a mask on a pane: a mask of the second close is not new")

        try key("p0", "second")
        let second = movers(acts[1])
        try #require(second.count == 1, "SETUP: the second close makes \(second.count) panes move, not 1")
        let grew = second[0]
        try #require(grew.layer.map { !Self.actMoves(acts[0], on: $0).isEmpty } ?? false,
                     "SETUP: the pane that grows in the second close has no move of the first close on its layer")
        // Each mask, and the acts that gave it a move with their own number.
        var masks: [(name: String, mask: PaneHoleMaskLayer, given: Set<Int>)] = []
        for (name, host) in [("first", left[0]), ("second", left[1])] {
            let mask = try #require(host.clipView.layer?.mask as? PaneHoleMaskLayer, "SETUP: the second close put no mask on the clip of the pane of the \(name) close")
            let onParts = Self.actsOnParts(of: mask)
            try #require(onParts[acts[1]] != nil, "SETUP: the mask on the pane of the \(name) close has no move of the second close on its parts")
            try #require(onParts[acts[0]] != nil, "SETUP: after the second key the mask on the pane of the \(name) close has no copy of the first close's move on its parts: the case of this row is not there")
            masks.append((name: name, mask: mask, given: [acts[1]]))
        }

        try key("p2", "third")
        try #require(left.allSatisfy { $0.isLeaving && !$0.isHidden }, "SETUP: the move does not keep the 3 panes that left")
        let third = movers(acts[2])
        try #require(third.count == 1, "SETUP: the third close makes \(third.count) panes move, not 1")
        try #require(third[0] === below && third[0] !== grew, "SETUP: the pane that grows in the third close is \(third[0].pane), not the pane below the 3")
        let layer = try #require(below.layer, "SETUP: the pane that grows in the third close has no layer")
        for (index, entry) in masks.enumerated() {
            try #require(left[index].clipView.layer?.mask === entry.mask, "SETUP: the third close does not use the mask on the pane of the \(entry.name) close again")
        }
        if let mask = left[2].clipView.layer?.mask as? PaneHoleMaskLayer { masks.append((name: "third", mask: mask, given: [])) }

        var prints: [String] = []
        for entry in masks {
            let onParts = Self.actsOnParts(of: entry.mask).sorted(by: { $0.key < $1.key })
            for (act, count) in onParts where act != acts[2] && !entry.given.contains(act) {
                let own = Self.actMoves(act, on: layer).count
                #expect(own > 0, """
                    after the third key the mask on the pane of the \(entry.name) close has \(count) moves of act \(act) on its parts. The pane that grows \
                    in the third close has no move of that act on its layer, and the mask got no move with that number in that act: they are copies \
                    of a move of a pane that does not move in this act, and they move the hole of the pane that grows
                    """)
            }
            prints.append("the mask on the pane of the \(entry.name) close: " + onParts.map { "\($0.value) of act \($0.key)" }.joined(separator: ", "))
        }
        let onLayer = Self.acts(on: screen).filter { !Self.actMoves($0, on: layer).isEmpty }
        print("ROW (THIRD KEY): the acts of the 3 close keys: \(acts); the pane that grew in the second close: \(grew.pane);",
              "the pane that grows in the third close: \(below.pane), with moves of the acts \(onLayer) on its layer;",
              "the moves on the parts of each mask after the third key: \(prints.joined(separator: "; "))")
    }
}
