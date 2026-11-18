import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, what goes with a pane's move and what a second act does to it: an act in the motion of
/// another, a hold of the split key, the pane that a close took out, a pane's ring, and the ground beside a pane
/// that gets smaller.
extension PaneCommitMotionTests {
    /// A tree of `leaves` panes in halves, each split across the one above it. One leaf more splits one pane and
    /// changes no other split: the first half of a split keeps the pane that was split.
    static func tree(_ leaves: Int, path: String = "") -> SplitNode {
        guard leaves > 1 else {
            var name = Substring(path)
            while name.last == "a" { name.removeLast() }
            return .leaf(PaneID("p\(name)"))
        }
        return .split(SplitID("s\(path)"), axis: path.count % 2 == 0 ? .horizontal : .vertical, ratio: 0.5,
                      a: tree((leaves + 1) / 2, path: path + "a"), b: tree(leaves / 2, path: path + "b"))
    }

    /// An act while the panes of another still move starts from where each pane shows. The second act's layout is the
    /// model in its own frame. Its move adds to the layer's model value and starts at the rect the first act gave the
    /// pane, and the first act's move stays on the layer: the two add up, so the pane does not jump. The second
    /// act's motion ends in its own time. This holds three frames into the first act's motion, and in its last tick:
    /// the second act comes one frame before the tick in which the first act's time is spent, and the frame that
    /// shows the second act takes the first act's move off no layer.
    @Test(arguments: [false, true])
    func aSecondActStartsFromThePresentPlace(inTheLastTick: Bool) throws {
        var frames = 3
        if inTheLastTick {
            // How many frames a split's motion takes after the frame that begins it: one run of it to its end.
            let whole = try Self.begin(Self.split)
            defer { whole.harness.window.closeAfterTest() }
            frames = Self.toTheEnd(whole.harness, whole.screen).ticks - 1
            try #require(frames > 3, "SETUP: a split's motion took \(frames + 1) frames")
        }
        let begun = try Self.begin(Self.split)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        for _ in 0..<frames { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "no pane moves \(frames) frames after the split's frame")
        let host = try #require(Self.hosts(of: screen)[Commit.left]), layer = try #require(host.layer)
        let first = Set(layer.animationKeys() ?? []), placed = layer.frame

        // The pane that the split made closes.
        harness.model.apply(screens: Commit.pair)
        let pair = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.places(pair, on: screen), "the first frame after the second act does not have its layout as its model: \(Self.hosts(of: screen).mapValues(\.frame))")
        let now = Set(layer.animationKeys() ?? [])
        #expect(first.isSubset(of: now), "the second act took the first act's move off the layer: the pane jumps to that move's end")
        let second = Self.move(of: layer, only: now.subtracting(first))
        #expect(second.moves, "the second act put no move on the pane's layer")
        #expect(second.animations.allSatisfy { $0.isAdditive }, "the second act's move does not add to the first act's")
        #expect(Commit.near(second.start, placed), "the second act's move starts at \(second.start), not at the rect the first act gave the pane: \(placed)")

        let (ticks, _) = Self.toTheEnd(harness, screen)
        #expect(Double(ticks) * Self.dt <= Self.close.time + 2 * Self.dt,
                "the second act's motion ended \(Double(ticks) * Self.dt) s after its frame; a close's time is \(Self.close.time) s")
        #expect(pair.isShown(by: Commit.shown(screen)), "after the motion's end the screen does not show the pair alone: \(Commit.shown(screen).panes)")
    }

    /// A hold of the split key: 10 splits, one each 4 display frames (the key's repeat of 30 ms at 120 Hz). No split
    /// waits behind a motion: the frame after each key has that split's layout as its model, whole, and so has each
    /// frame to the next key. The last layout is alone on the screen at most one split's time after the last key.
    @Test func aHoldOfTheSplitKeyNeverQueuesAMotion() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(1)), focused: "p", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        var moved = false
        var last = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        for leaves in 2...11 {
            harness.model.apply(screens: Commit.screen(Self.tree(leaves)))
            last = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
            harness.root.syncWithModel()
            for tick in 1...4 {
                _ = harness.root.advanceFrame(Self.dt)
                let frame = Commit.shown(screen)
                #expect(last.isShown(by: frame), "split \(leaves - 1), frame \(tick): the screen's layout is not that split's: \(frame.panes.count) panes")
                #expect(frame.misfits.isEmpty, "split \(leaves - 1), frame \(tick): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
            }
            moved = moved || Self.inFlight(screen)
        }
        #expect(moved, "no pane moved in the hold: each split shows in one frame")
        // Three frames were stepped after the frame that showed the last split.
        let (ticks, _) = Self.toTheEnd(harness, screen)
        #expect(Double(ticks + 3) * Self.dt <= Self.split.time + 2 * Self.dt,
                "the motion ended \(Double(ticks + 3) * Self.dt) s after the frame that showed the last split; a split's time is \(Self.split.time) s")
        #expect(last.isShown(by: Commit.shown(screen)), "after the hold the screen does not show the last layout alone")
        #expect(!harness.root.advanceFrame(Self.dt) || !harness.root.advanceFrame(Self.dt), "frames run on after the hold's last motion")
    }

    /// A hold of the close key: 10 closes, one each 4 display frames. No close waits behind a motion: the frame after
    /// each key has that close's layout as its model, whole, and so has each frame to the next key. The panes that
    /// the closes took out can still show under the others in that time. The last layout is alone on the screen at
    /// most one close's time after the last key.
    @Test func aHoldOfTheCloseKeyNeverQueuesAMotion() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(11)), focused: "p", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        var moved = false
        var last = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        try #require(last.isShown(by: Commit.shown(screen)), "SETUP: the screen does not rest at the 11 panes")
        for leaves in (1...10).reversed() {
            harness.model.apply(screens: Commit.screen(Self.tree(leaves)))
            last = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
            harness.root.syncWithModel()
            for tick in 1...4 {
                _ = harness.root.advanceFrame(Self.dt)
                let frame = Commit.shown(screen)
                #expect(Self.places(last, on: screen), "close \(11 - leaves), frame \(tick): the screen's layout is not that close's: \(frame.panes.count) panes")
                let misfits = frame.misfits.filter { last.panes[$0.key] != nil }
                #expect(misfits.isEmpty, "close \(11 - leaves), frame \(tick): a pane's content is not at the rect its pane gives it: \(misfits)")
            }
            moved = moved || Self.inFlight(screen)
        }
        #expect(moved, "no pane moved in the hold: each close shows in one frame")
        // Three frames were stepped after the frame that showed the last close.
        let (ticks, _) = Self.toTheEnd(harness, screen)
        #expect(Double(ticks + 3) * Self.dt <= Self.close.time + 2 * Self.dt,
                "the motion ended \(Double(ticks + 3) * Self.dt) s after the frame that showed the last close; a close's time is \(Self.close.time) s")
        #expect(last.isShown(by: Commit.shown(screen)), "after the hold the screen does not show the last layout alone: \(Commit.shown(screen).panes)")
        #expect(!harness.root.advanceFrame(Self.dt) || !harness.root.advanceFrame(Self.dt), "frames run on after the hold's last motion")
    }

    /// A change of the screen's size while a split waits for its frame takes the move from that split, and from a
    /// split that comes before that frame too: where the panes showed before both is not where they show now. The
    /// surfaces of this test never report, so the two splits show when the wait's bound is spent.
    @Test func aSplitBeforeTheFrameOfAChangeThatAResizeStilledDoesNotMove() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(2)), focused: "p", holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Commit.screen(Self.tree(3)))
        harness.root.syncWithModel()
        harness.window.setContentSize(NSSize(width: 1400, height: 900))
        harness.root.layoutSubtreeIfNeeded()
        try #require(screen.frameInput.snapWaitsForContent, "SETUP: the first split does not wait for its frame after the change of the screen's size")
        harness.model.apply(screens: Commit.screen(Self.tree(4)))
        let last = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        let moved = (0...ScreenContentView.commitBound).contains { _ in _ = harness.root.advanceFrame(Self.dt); return Self.inFlight(screen) }
        #expect(!moved, "a split moved its panes from where they showed before the change of the screen's size")
        #expect(last.isShown(by: Commit.shown(screen)), "the two splits did not show in the bound of their wait: \(Commit.shown(screen).panes)")
    }

    /// The pane that a close took out shows in each frame of the motion, so its neighbour grows over it and not over
    /// the window's backdrop. The frame that ends the motion hides it.
    @Test func aClosedPaneShowsToTheMotionsEndAndHidesWithIt() throws {
        let begun = try Self.begin(Self.close)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        func closed() -> PaneHostView? {
            screen.subviews.lazy.compactMap { $0 as? PaneHostView }.first { $0.pane == Commit.added }
        }
        try #require(Self.inFlight(screen), "no pane moves: the close shows in one frame")
        var frame = 1
        while Self.inFlight(screen), frame < Commit.frames {
            #expect(closed().map { !$0.isHidden && $0.alphaValue > 0 } ?? false, "frame \(frame) of the close's motion does not show the closed pane")
            _ = harness.root.advanceFrame(Self.dt)
            frame += 1
        }
        #expect(closed().map(\.isHidden) ?? true, "the closed pane still shows after the motion's end")
        #expect(begun.new.isShown(by: Commit.shown(screen)), "after the motion's end the screen does not show the pair alone: \(Commit.shown(screen).panes)")
    }

    /// A pane's ring and border are in the layout's overlay plane, not in the pane's host. They get the pane's move:
    /// from where they showed before the act, with the timing of the host's move.
    @Test(arguments: PaneCommitMotionTests.acts)
    func aPanesRingMovesWithItsPane(_ act: Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        try #require(Self.inFlight(begun.screen), "no pane moves: the act shows in one frame")
        var rings = 0
        for (pane, host) in Self.hosts(of: begun.screen) {
            guard let was = begun.rings[pane], !host.chrome.isHidden, let ring = host.chrome.layer, let layer = host.layer else { continue }
            let move = Self.move(of: layer)
            guard move.moves else { continue }
            rings += 1
            let follows = Self.move(of: ring)
            #expect(follows.moves, "\(pane) moves and its ring has no move on its layer: the ring shows at the pane's new rect at once")
            #expect(Commit.near(follows.start, was), "\(pane)'s ring starts its move at \(follows.start), not where it showed: \(was)")
            #expect(Commit.near(follows.end, ring.frame), "\(pane)'s ring ends its move at \(follows.end), not at its layer's frame: \(ring.frame)")
            #expect(follows.issues.isEmpty, "\(pane)'s ring: \(follows.issues)")
            let timings = Set((move.animations + follows.animations).map { Self.timing($0) })
            #expect(timings.count == 1, "\(pane) and its ring move with \(timings.count) timings: \(timings)")
        }
        #expect(rings > 0, "SETUP: no pane that moves shows a ring")
    }

    /// The name of a layer that shows a pane's own ground beside its content while the pane's clip gets smaller.
    static let groundStrip = "pane.commit.ground"

    /// A split's old pane gets smaller, and its content has its final size from the first frame: the rest of its old
    /// rect shows the pane's own ground until the moving edge closes it. In each frame of the motion strip layers in
    /// the pane's host have the color of the pane's own content, never another pane's, and with the content they
    /// cover the rect the pane had. No strip is under the content: a see-through content keeps its strength. The
    /// frame that ends the motion takes the strips away, and the host's own ground and its clip's are as before.
    @Test func theGroundBesideAPaneThatGetsSmallerIsItsOwn() throws {
        let own = CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), other = CGColor(red: 0.1, green: 0.1, blue: 0.8, alpha: 1)
        var before: [CGColor?] = []
        let begun = try Self.begin(Self.split) { harness in
            harness.provider.contents[Commit.left]?.layer?.backgroundColor = own
            harness.provider.contents[Commit.right]?.layer?.backgroundColor = other
            let host = harness.root.context.hosts[Commit.left]
            before = [host?.layer?.backgroundColor, host?.clipView.layer?.backgroundColor]
        }
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let host = try #require(Self.hosts(of: screen)[Commit.left])
        let had = try #require(begun.was[Commit.left]?.size, "SETUP: the pane did not show before the split")
        try #require(host.content.paneGroundColor == own, "SETUP: the pane's content does not report the ground the test gave it")
        try #require(Self.inFlight(screen), "no pane moves: the split shows in one frame")
        func strips() -> [CALayer] { (host.layer?.sublayers ?? []).filter { $0.name == Self.groundStrip } }
        let content = CGRect(origin: .zero, size: host.frame.size)
        var frame = 1
        while Self.inFlight(screen), frame < Commit.frames {
            let shown = strips()
            #expect(!shown.isEmpty, "frame \(frame) of the split's motion: no ground is beside the pane's content")
            #expect(shown.allSatisfy { $0.backgroundColor == own }, "frame \(frame) of the split's motion: a ground is not of the pane's own color")
            #expect(shown.allSatisfy { $0.frame.intersection(content).width < 0.5 || $0.frame.intersection(content).height < 0.5 },
                    "frame \(frame) of the split's motion: a ground is under the pane's content: \(shown.map(\.frame))")
            let open = Self.uncovered(shown.map(\.frame) + [content], in: CGRect(origin: .zero, size: had))
            #expect(open < 1, "frame \(frame) of the split's motion: \(open) pt2 of the rect the pane had shows no ground of its own")
            _ = harness.root.advanceFrame(Self.dt)
            frame += 1
        }
        #expect(strips().isEmpty, "after the motion's end the pane keeps the motion's ground")
        #expect([host.layer?.backgroundColor, host.clipView.layer?.backgroundColor] == before, "the motion changed the host's own ground or its clip's")
    }
}
