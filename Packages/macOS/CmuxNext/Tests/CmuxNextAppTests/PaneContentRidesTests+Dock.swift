import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneContentRidesTests`, a page in a dock column (the docked Home's place).
///
/// A dock that is alone on its screen fills the screen. The first column that opens beside it makes it a dock at its
/// edge: its pane gets smaller, so its page is held to the motion's end as each page is. A dock that has a column
/// beside it keeps its frame when that column's pane splits: the dock's width comes from the dock alone, so its page
/// takes no size and is not held.
extension PaneContentRidesTests {
    static func dock(width: CGFloat) -> LayoutColumn {
        LayoutColumn(id: "dock", width: width, root: .leaf(Commit.left), dock: DockColumn(edge: .left, mode: .docked))
    }

    static func columns(_ columns: [LayoutColumn]) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .columns(columns), zoomed: false)]
    }

    /// The dock alone, then with one column beside it, then with that column's pane split down.
    static var dockAlone: [LayoutScreen] { columns([dock(width: 0.5)]) }
    static var dockBesideAColumn: [LayoutScreen] {
        columns([dock(width: 0.5), LayoutColumn(id: "beside", width: 1, root: .leaf(Commit.right))])
    }
    static var dockBesideASplitColumn: [LayoutScreen] {
        let halves = SplitNode.split(SplitID("new"), axis: .vertical, ratio: 0.5, a: .leaf(Commit.right), b: .leaf(Commit.added))
        return columns([dock(width: 0.5), LayoutColumn(id: "beside", width: 1, root: halves)])
    }

    /// The screen at rest at `screens` with the pane animations on and a page's view in each pane.
    static func rested(at screens: [LayoutScreen]) throws -> (harness: Commit.Harness, screen: ScreenContentView) {
        let harness = Commit.Harness(screens, focused: Commit.left, holds: true)
        Motion.movePanes(harness)
        Commit.rest(harness)
        for content in harness.provider.contents.values { _ = showPicture(in: content) }
        Commit.rest(harness)
        guard let screen = harness.screen, !Motion.inFlight(screen) else {
            harness.window.closeAfterTest()
            throw DockSetup.noRest
        }
        return (harness, screen)
    }

    enum DockSetup: Error { case noRest }

    /// The first split of a window that shows only its docked page: the page's pane goes from the whole screen to
    /// its dock. Its content keeps the size it had from the frame that shows the act to the motion's end, under its
    /// pane's moving clip, and takes its pane's size one time, in the frame that ends the motion.
    @Test func theFirstColumnBesideALoneDockMovesTheDocksPaneAndItsPageIsHeldToTheEnd() throws {
        let (harness, screen) = try Self.rested(at: Self.dockAlone)
        defer { harness.window.closeAfterTest() }
        let host = try #require(Motion.hosts(of: screen)[Commit.left], "SETUP: the dock's pane does not show")
        let content = try #require(harness.provider.contents[Commit.left])
        let was = try #require(host.layer?.frame), before = host.content.frame.size, sizes = content.sizes.count
        try #require(was.width > screen.bounds.width * 0.9, "SETUP: the lone dock's pane is \(was.width) wide on a screen of \(screen.bounds.width): it does not fill it")

        harness.model.apply(screens: Self.dockBesideAColumn)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)

        let shown = Motion.hosts(of: screen)
        try #require(shown[Commit.left] === host, "SETUP: the dock's pane has another host after the act")
        #expect(shown[Commit.right] != nil, "the frame that shows the act does not show the new column's pane")
        try #require(host.frame.width < was.width - 1, "SETUP: the dock's pane is \(host.frame.width) wide after the act; it was \(was.width)")
        let layer = try #require(host.layer)
        try #require(Motion.inFlight(screen), "no pane moves: the first column beside a lone dock shows in one frame")
        let move = Motion.move(of: layer)
        #expect(move.moves, "the dock's pane went from \(was) to \(host.frame) with no move on its layer")
        #expect(Commit.near(move.start, was), "the dock's pane's move starts at \(move.start), not where the pane showed: \(was)")
        #expect(move.issues.isEmpty, "the dock's pane: \(move.issues)")
        #expect(host.holdsContentForMove, "the dock's pane gets smaller and its host does not hold its page")
        var tick = 0
        while Motion.inFlight(screen), tick < Commit.frames {
            #expect(content.sizes.count == sizes, "frame \(tick): the dock's page took a size while its pane moves: \(content.sizes.suffix(content.sizes.count - sizes))")
            #expect(Self.near(host.content.frame.size, before), "frame \(tick): the dock's page is \(host.content.frame.size); it was \(before)")
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        }
        Commit.rest(harness)
        let took = content.sizes.count - sizes
        #expect(took == 1, "the dock's page took \(took) sizes in one act: \(content.sizes.suffix(took)); it takes its pane's size one time")
        #expect(!host.holdsContentForMove, "after the motion's end the dock's pane holds its page at the old size")
        #expect(host.content.frame == host.clipView.bounds, "after the motion's end the dock's page is \(host.content.frame) in a clip of \(host.clipView.bounds)")
        #expect(host.content.frame.width < before.width - 1, "after the motion's end the dock's page is \(host.content.frame.size), no narrower than the \(before) before the act")
    }

    /// A split of the pane beside a dock changes no edge of the dock: the dock's pane has no move, and its page takes
    /// no size and is not held, from the act to the motion's end.
    @Test func aSplitOfThePaneBesideADockLeavesTheDocksPaneAndItsPageAsTheyAre() throws {
        let (harness, screen) = try Self.rested(at: Self.dockBesideAColumn)
        defer { harness.window.closeAfterTest() }
        let host = try #require(Motion.hosts(of: screen)[Commit.left], "SETUP: the dock's pane does not show")
        let beside = try #require(Motion.hosts(of: screen)[Commit.right], "SETUP: the pane beside the dock does not show")
        let content = try #require(harness.provider.contents[Commit.left])
        let was = host.frame, tall = beside.frame.height, sizes = content.sizes.count

        harness.model.apply(screens: Self.dockBesideASplitColumn)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)

        try #require(beside.frame.height < tall - 1, "SETUP: the split did not make the pane beside the dock lower: \(beside.frame.height), before \(tall)")
        var tick = 0
        repeat {
            #expect(Commit.near(host.frame, was), "frame \(tick): the dock's pane is at \(host.frame); a split of the pane beside it changes no edge of \(was)")
            let layer = try #require(host.layer)
            let moves = Motion.move(of: layer).moves
            #expect(!moves, "frame \(tick): the dock's pane has a move on its layer")
            #expect(!host.holdsContentForMove, "frame \(tick): the dock's host holds its page; its pane did not get smaller")
            #expect(content.sizes.count == sizes, "frame \(tick): the dock's page took a size: \(content.sizes.suffix(content.sizes.count - sizes))")
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        } while Motion.inFlight(screen) && tick < Commit.frames
    }
}
