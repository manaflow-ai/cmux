import AppKit
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// Zoom and unzoom (Cmd-Shift-Enter) have no motion between two layouts: each shows whole in one frame, the first
/// display frame after its change. The zoomed pane fills its screen with its content at that size, and the other
/// panes are hidden with it; an unzoom shows every pane at its place again. No frame shows the zoomed pane at a size
/// between its slot and its screen, or a pane beside it that the layout does not have.
///
/// The oracle is the layout engine's rest geometry of the model (`PaneLayoutCommitTests.Rest`), and the test is the
/// clock: it steps the layout's frames itself.
@MainActor
@Suite(.closesItsWindows) struct PaneZoomMotionTests {
    typealias Commit = PaneLayoutCommitTests

    /// A 2 by 2 grid: p1 over p2 on the left, p3 over p4 on the right.
    static let grid: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                        a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                        b: .split("b", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    static func screens(zoomedOn pane: PaneID? = nil) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .splits(pane.map { .leaf($0) } ?? grid), zoomed: pane != nil)]
    }

    /// What follows the panes in one frame: the divider lines the screen reports (content drawn above the window, a
    /// Chromium page, leaves them uncovered), and the panes a zoom on p4 covers whose ring shows.
    struct Follows {
        var lines: [CGRect]
        var ringed: [PaneID]
    }

    /// The frames one change shows: the frame of its own turn, then `Commit.frames` display frames; and what follows
    /// the panes in each of them (the rings of `covered`).
    static func frames(of harness: Commit.Harness, after change: [LayoutScreen], covered: [PaneHostView] = [])
        throws -> (shown: [Commit.Frame], rest: Commit.Rest, follows: [Follows]) {
        let screen = try #require(harness.screen)
        harness.model.apply(screens: change)
        let rest = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        func follows() -> Follows {
            Follows(lines: harness.root.interactiveOverlayRects, ringed: covered.filter { !$0.chrome.isHidden }.map(\.pane))
        }
        var shown = [Commit.shown(screen)], followed = [follows()]
        for _ in 0..<Commit.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Commit.shown(screen))
            followed.append(follows())
        }
        return (shown, rest, followed)
    }

    /// The hosts of the panes a zoom on p4 covers, each with its ring showing. Read before the zoom: while the screen
    /// is zoomed the layout keeps them, hidden, out of its hosts (`LayoutViewContext.retired`).
    static func coveredHosts(of harness: Commit.Harness) throws -> [PaneHostView] {
        let hosts = [PaneID("p1"), PaneID("p2"), PaneID("p3")].compactMap { harness.root.context.hosts[$0] }
        let ringsShow = hosts.allSatisfy { !$0.chrome.isHidden }
        try #require(hosts.count == 3 && ringsShow,
                     "set-up: a pane the zoom covers has no host, or its ring is hidden before the zoom: \(hosts.map(\.pane))")
        return hosts
    }

    /// The grid at rest in the hand-built look, whose splits draw their line at rest whatever pane separation the
    /// settings of this process chose (the tests read the lines): the harness, the hosts a zoom on p4 covers and the
    /// divider lines the grid reports.
    static func gridAtRest() throws -> (harness: Commit.Harness, covered: [PaneHostView], lines: [CGRect]) {
        let harness = Commit.Harness(Self.screens(), focused: "p4", holds: false) { $0.followsDesignMetrics = false }
        Commit.rest(harness)
        let lines = harness.root.interactiveOverlayRects
        try #require(!lines.isEmpty, "set-up: the grid reports no divider line at rest")
        let covered = try Self.coveredHosts(of: harness)
        return (harness, covered, lines)
    }

    @Test func aZoomShowsThePaneAtItsScreensSizeInOneFrame() throws {
        let (harness, covered, lines) = try Self.gridAtRest()
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        let grid = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        let (shown, zoomed, follows) = try Self.frames(of: harness, after: Self.screens(zoomedOn: "p4"), covered: covered)
        #expect(grid.isShown(by: shown[0]), "the zoom's own turn changed what the screen shows: \(shown[0].panes)")
        // What follows the panes shows the layout the panes show, in each frame. The zoom's own turn still shows the
        // grid: the screen reports the lines of the dividers it shows, and each pane keeps its ring.
        #expect(follows[0].lines == lines, "the zoom's own turn reports other divider lines than the screen shows: \(follows[0].lines)")
        #expect(follows[0].ringed.count == covered.count, "the zoom's own turn hid the ring of a pane the screen still shows: \(follows[0].ringed)")
        for (index, frame) in shown.dropFirst().enumerated() {
            #expect(zoomed.isShown(by: frame), "frame \(index + 1) of the zoom does not show the zoomed pane alone at its screen's size: \(frame.panes)")
            #expect(frame.misfits.isEmpty, "frame \(index + 1): the zoomed pane's content is not at the rect its pane gives it: \(frame.misfits)")
            // The zoomed pane alone: no divider line for a page to leave uncovered, and no ring of a covered pane.
            #expect(follows[index + 1].lines.isEmpty && follows[index + 1].ringed.isEmpty,
                    "frame \(index + 1) of the zoom still reports divider lines or shows a covered pane's ring: \(follows[index + 1])")
        }
        #expect(Set(zoomed.panes.keys) == ["p4"] && zoomed.dividers.isEmpty, "the zoomed layout is not one pane: \(zoomed.panes)")
        // A zoom's covered panes are still in the layout (focus topology, theme): the provider keeps them all.
        #expect(harness.provider.shown == ["p1", "p2", "p3", "p4"], "a zoom took a pane out of the provider's shown panes: \(harness.provider.shown)")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a zoom that showed still asks for frames")
    }

    @Test func anUnzoomShowsEveryPaneAtItsPlaceInOneFrame() throws {
        let (harness, covered, lines) = try Self.gridAtRest()
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        let made = harness.provider.contents.count
        _ = try Self.frames(of: harness, after: Self.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        let (shown, grid, follows) = try Self.frames(of: harness, after: Self.screens(), covered: covered)
        #expect(zoomed.isShown(by: shown[0]), "the unzoom's own turn changed what the screen shows: \(shown[0].panes)")
        // The unzoom's own turn still shows the zoom, and what follows the panes shows it with them: no line of a
        // divider to come, and no ring of a pane the zoom still covers.
        #expect(follows[0].lines.isEmpty && follows[0].ringed.isEmpty,
                "the unzoom's own turn reports divider lines or shows rings that the screen does not show yet: \(follows[0])")
        for (index, frame) in shown.dropFirst().enumerated() {
            #expect(grid.isShown(by: frame), "frame \(index + 1) of the unzoom does not show every pane at its place: \(frame.panes)")
            #expect(frame.misfits.isEmpty, "frame \(index + 1): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
            // Every pane at its place: the lines between them and each pane's ring are back, as before the zoom.
            #expect(follows[index + 1].lines == lines && follows[index + 1].ringed.count == covered.count,
                    "frame \(index + 1) of the unzoom does not report the grid's divider lines, or a pane has no ring: \(follows[index + 1])")
        }
        #expect(harness.provider.contents.count == made && harness.provider.released.isEmpty,
                "the zoom or the unzoom made or released a pane: \(harness.provider.contents.count) made, \(harness.provider.released) released")
    }

    /// A second Cmd-Shift-Enter before the zoom showed: the screen never leaves the layout it showed.
    @Test func aZoomTurnedBackBeforeItShowedChangesNoFrame() throws {
        let harness = Commit.Harness(Self.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let grid = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        harness.model.apply(screens: Self.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        let (shown, _, _) = try Self.frames(of: harness, after: Self.screens())
        for (index, frame) in shown.enumerated() {
            #expect(grid.isShown(by: frame), "frame \(index) shows another layout after the zoom was turned back: \(frame.panes)")
        }
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }
}
