import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A pane whose content is a page's picture (a page, a chat) rides its pane's move as each pane does, and its picture
/// is never cut and never scaled on the way.
///
/// A page draws in another process: its picture at a new size comes some display frames after its view takes that
/// size, and until then its view shows the last picture at the old size, cut where the view is smaller. So content of
/// this kind (the provider's rule `holdsContentInMotion`) takes no size in a frame that would cut its picture:
///
/// - A pane that gets smaller (the pane a split halves, the pane an unzoom gives its place back) keeps its content at
///   the size it had before the act from the frame that shows the act to the motion's end: the picture is whole under
///   the pane's moving clip. The frame that ends the motion gives the content its final size, one time.
/// - A second act that gives the pane its old size back resizes nothing: the content never left that size.
///
/// The test is the clock (`PaneCommitMotionTests`): it steps the layout's frames itself and reads each size the
/// content takes. It makes no page: the content is a plain view that records its sizes, so these rows hold the
/// layout's part only. What a page's layer shows is not read here.
@MainActor
@Suite(.closesItsWindows) struct PaneContentRidesTests {
    typealias Commit = PaneLayoutCommitTests
    typealias Motion = PaneCommitMotionTests

    /// One act, begun on panes whose content the provider holds, and what each content was before it.
    struct Begun {
        let motion: Motion.Begun
        /// How many sizes each pane's content had taken before the act.
        let sizes: [PaneID: Int]
        /// Each pane's content size before the act.
        let contents: [PaneID: CGSize]

        var harness: Commit.Harness { motion.harness }
        var screen: ScreenContentView { motion.screen }

        /// The panes of the layout after the act that are narrower or lower than before it.
        var smaller: [PaneID] {
            motion.new.panes.compactMap { pane, rect in
                guard let old = motion.old.panes[pane] else { return nil }
                return rect.width < old.width - 1 || rect.height < old.height - 1 ? pane : nil
            }
        }
    }

    /// An unzoom gives the zoomed pane its place in the layout back: the pane gets smaller.
    nonisolated static let unzoom = PaneCommitMotionTests.Act(name: "unzoom", time: PaneCommitMotionTests.zoom.time)
    /// The acts that make a pane smaller. A split to the left or up moves the old pane's origin too.
    nonisolated static let shrinks = ["split right", "split down", "split left", "split up"].map {
        PaneCommitMotionTests.Act(name: $0, time: PaneCommitMotionTests.split.time)
    } + [unzoom]
    /// Each act that moves a pane.
    nonisolated static let moves = shrinks + [PaneCommitMotionTests.close, PaneCommitMotionTests.zoom]

    /// The pair with a new pane before its left pane along `axis` (`.horizontal`: at its left, `.vertical`: above it).
    static func pairSplitBefore(_ axis: SplitAxis) -> [LayoutScreen] {
        let halves = SplitNode.split(SplitID("new"), axis: axis, ratio: 0.5, a: .leaf(Commit.added), b: .leaf(Commit.left))
        return Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: halves, b: .leaf(Commit.right)))
    }

    /// The pair split to the right, with its left pane split down again: that pane is a quarter as wide and half as
    /// high as in the pair.
    static var pairSplitTwice: [LayoutScreen] {
        let again = SplitNode.split(SplitID("again"), axis: .vertical, ratio: 0.5, a: .leaf(Commit.left), b: .leaf(PaneID("again")))
        let halves = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: again, b: .leaf(Commit.added))
        return Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: halves, b: .leaf(Commit.right)))
    }

    static func layouts(of act: Motion.Act) -> (before: [LayoutScreen], after: [LayoutScreen]) {
        switch act.name {
        case "split left": (Commit.pair, pairSplitBefore(.horizontal))
        case "split up": (Commit.pair, pairSplitBefore(.vertical))
        default: Commit.layouts(of: Commit.Change(name: act.name, holds: true))
        }
    }

    /// The screen rests at the layout before `act` with the pane animations on, then the act comes in its own turn
    /// and the first display frame after it is stepped: the frame that shows the change.
    static func begin(_ act: Motion.Act) throws -> Begun {
        let (before, after) = layouts(of: act)
        // An unzoom starts from a zoom the screen showed: the pane that zoom covered comes back, it is not made.
        let harness = Commit.Harness(act.name == "unzoom" ? Commit.pair : before, focused: Commit.left, holds: true)
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        Motion.movePanes(harness)
        if act.name == "unzoom" {
            Commit.rest(harness)
            harness.model.apply(screens: before)
            harness.root.syncWithModel()
        }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Commit.Rest(harness.model.screens, in: screen, style: style)
        let rested = Commit.shown(screen)
        try #require(old.isShown(by: rested) && rested.misfits.isEmpty && !Motion.inFlight(screen),
                     "SETUP: the screen does not rest at the layout before the act: \(rested.panes)")
        let shown = Motion.hosts(of: screen)
        let was = shown.compactMapValues { $0.layer?.frame }
        let sizes = harness.provider.contents.mapValues { $0.sizes.count }
        let contents = shown.mapValues { $0.content.frame.size }
        harness.model.apply(screens: after)
        let new = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        let asks = harness.root.advanceFrame(Motion.dt)
        begun = true
        let motion = Motion.Begun(harness: harness, screen: screen, old: old, new: new, was: was, rings: [:], asks: asks)
        return Begun(motion: motion, sizes: sizes, contents: contents)
    }

    static func near(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 1.02 && abs(a.height - b.height) <= 1.02
    }

    // MARK: Tests

    /// A pane whose content the provider holds moves as each pane does: the frame that shows the act has the layout
    /// after it as its model, and each pane whose rect changed has a move on its layer from where it showed.
    @Test(arguments: moves)
    func aPaneWithHeldContentHasItsMoveOnItsLayer(_ act: Motion.Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let hosts = Motion.hosts(of: begun.screen)
        #expect(Motion.places(begun.motion.new, on: begun.screen),
                "the first frame after the act does not have each pane of the new layout at its rest rect: \(hosts.mapValues(\.frame))")
        var moved = 0
        for (pane, was) in begun.motion.was {
            guard let rect = begun.motion.new.panes[pane], let old = begun.motion.old.panes[pane], !Commit.near(old, rect) else { continue }
            moved += 1
            let layer = try #require(hosts[pane]?.layer, "\(pane) does not show in the frame that shows the act")
            let move = Motion.move(of: layer)
            #expect(move.moves, "\(pane), whose content is held, went from \(old) to \(rect) with no move on its layer: it shows at its new rect at once")
            #expect(Commit.near(move.start, was), "\(pane)'s move starts at \(move.start), not where the pane showed: \(was)")
            #expect(move.issues.isEmpty, "\(pane): \(move.issues)")
        }
        #expect(moved > 0, "SETUP: the act changed no pane's rect")
    }

    /// The content of a pane that gets smaller keeps the size it had before the act in the frame that shows the act
    /// and in each frame of the motion: its picture is whole under the moving clip. The frame that ends the motion
    /// gives it its final size, one time.
    @Test(arguments: shrinks)
    func theContentOfAPaneThatGetsSmallerKeepsItsSizeToTheMotionsEnd(_ act: Motion.Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let smaller = begun.smaller
        try #require(!smaller.isEmpty, "SETUP: the act makes no pane smaller")
        let contents = harness.provider.contents
        func took(_ pane: PaneID) -> Int { (contents[pane]?.sizes.count ?? 0) - (begun.sizes[pane] ?? 0) }

        for pane in smaller {
            let content = try #require(contents[pane]), before = try #require(begun.contents[pane])
            // A page's picture is cut by a size it takes here: no pane covers that part of it yet.
            #expect(took(pane) == 0,
                    "\(pane) gets smaller and its content took \(took(pane)) sizes in the frame that shows the act: \(content.sizes.suffix(took(pane)))")
            #expect(Self.near(content.frame.size, before), "\(pane)'s content is \(content.frame.size) in the frame that shows the act; it was \(before)")
        }
        var tick = 1
        while Motion.inFlight(screen), tick < Commit.frames {
            for pane in smaller {
                #expect(took(pane) == 0, "frame \(tick): \(pane)'s content took a size while its pane moves")
            }
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        }
        #expect(tick > 1, "no pane moves: the act shows in one frame")
        let end = Commit.shown(screen), hosts = Motion.hosts(of: screen)
        for pane in smaller {
            let content = try #require(contents[pane]), before = try #require(begun.contents[pane])
            let final = try #require(hosts[pane]?.contentRect.size, "\(pane) does not show after the motion's end")
            #expect(took(pane) == 1, "\(pane)'s content took \(took(pane)) sizes in one act: \(content.sizes.suffix(took(pane))); it takes its final size one time")
            #expect(final.width < before.width - 1 || final.height < before.height - 1,
                    "after the motion's end \(pane) gives its content \(final), no smaller than the \(before) before the act")
            #expect(Self.near(content.frame.size, final), "after the motion's end \(pane)'s content is \(content.frame.size); its pane gives it \(final)")
            #expect(end.misfits[pane] == nil, "after the motion's end \(pane)'s content is not at the rect its pane gives it")
        }
        #expect(begun.motion.new.isShown(by: end), "after the motion's end the screen shows more or less than the layout after the act: \(end.panes)")
    }

    /// A split, and three frames later the close of the pane that the split made: the pane that the split halved has
    /// its old size back. Its content never left that size, so the two acts resize it zero times.
    @Test func aSecondActThatGivesTheOldSizeBackResizesNothing() throws {
        let begun = try Self.begin(Motion.split)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let content = try #require(harness.provider.contents[Commit.left]), before = try #require(begun.contents[Commit.left])
        for _ in 0..<3 { _ = harness.root.advanceFrame(Motion.dt) }

        // The pane that the split made closes.
        harness.model.apply(screens: Commit.pair)
        let pair = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)

        let took = content.sizes.count - (begun.sizes[Commit.left] ?? 0)
        #expect(took == 0, "a split and the close of its new pane resized the first pane's content \(took) times: \(content.sizes.suffix(took)); it never left \(before)")
        #expect(Self.near(content.frame.size, before), "after the two acts the first pane's content is \(content.frame.size); it was \(before)")
        let end = Commit.shown(screen)
        #expect(pair.isShown(by: end) && end.misfits.isEmpty, "after the two acts the screen does not show the pair with each content at its pane's rect: \(end.panes)")
    }

    /// A split, and three frames later a second split of the same pane: the pane gets smaller two times, and its
    /// content takes one size, the last one.
    @Test func aSecondActThatMakesThePaneSmallerAgainResizesItOneTime() throws {
        let begun = try Self.begin(Motion.split)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let content = try #require(harness.provider.contents[Commit.left]), before = try #require(begun.contents[Commit.left])
        for _ in 0..<3 { _ = harness.root.advanceFrame(Motion.dt) }

        harness.model.apply(screens: Self.pairSplitTwice)
        let twice = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)

        let took = content.sizes.count - (begun.sizes[Commit.left] ?? 0)
        #expect(took == 1, "two splits of one pane resized its content \(took) times: \(content.sizes.suffix(took)); it takes the last size one time")
        let end = Commit.shown(screen)
        let final = try #require(Motion.hosts(of: screen)[Commit.left]?.contentRect.size, "the first pane does not show after the two acts")
        #expect(final.width < before.width - 1 && final.height < before.height - 1,
                "after the two acts the first pane gives its content \(final), not smaller both ways than the \(before) before them")
        #expect(Self.near(content.frame.size, final), "after the two acts the first pane's content is \(content.frame.size); its pane gives it \(final)")
        #expect(twice.isShown(by: end) && end.misfits.isEmpty, "after the two acts the screen does not show the last layout with each content at its pane's rect: \(end.panes)")
    }
}
