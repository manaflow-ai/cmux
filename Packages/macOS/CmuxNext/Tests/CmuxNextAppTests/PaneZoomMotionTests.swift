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

    /// The frames one change shows: the frame of its own turn, then `Commit.frames` display frames.
    static func frames(of harness: Commit.Harness, after change: [LayoutScreen]) throws -> (shown: [Commit.Frame], rest: Commit.Rest) {
        let screen = try #require(harness.screen)
        harness.model.apply(screens: change)
        let rest = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        var shown = [Commit.shown(screen)]
        for _ in 0..<Commit.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Commit.shown(screen))
        }
        return (shown, rest)
    }

    @Test func aZoomShowsThePaneAtItsScreensSizeInOneFrame() throws {
        let harness = Commit.Harness(Self.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let grid = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        let (shown, zoomed) = try Self.frames(of: harness, after: Self.screens(zoomedOn: "p4"))
        #expect(grid.isShown(by: shown[0]), "the zoom's own turn changed what the screen shows: \(shown[0].panes)")
        for (index, frame) in shown.dropFirst().enumerated() {
            #expect(zoomed.isShown(by: frame), "frame \(index + 1) of the zoom does not show the zoomed pane alone at its screen's size: \(frame.panes)")
            #expect(frame.misfits.isEmpty, "frame \(index + 1): the zoomed pane's content is not at the rect its pane gives it: \(frame.misfits)")
        }
        #expect(Set(zoomed.panes.keys) == ["p4"] && zoomed.dividers.isEmpty, "the zoomed layout is not one pane: \(zoomed.panes)")
        // A zoom's covered panes are still in the layout (focus topology, theme): the provider keeps them all.
        #expect(harness.provider.shown == ["p1", "p2", "p3", "p4"], "a zoom took a pane out of the provider's shown panes: \(harness.provider.shown)")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a zoom that showed still asks for frames")
    }

    @Test func anUnzoomShowsEveryPaneAtItsPlaceInOneFrame() throws {
        let harness = Commit.Harness(Self.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let made = harness.provider.contents.count
        _ = try Self.frames(of: harness, after: Self.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)

        let (shown, grid) = try Self.frames(of: harness, after: Self.screens())
        #expect(zoomed.isShown(by: shown[0]), "the unzoom's own turn changed what the screen shows: \(shown[0].panes)")
        for (index, frame) in shown.dropFirst().enumerated() {
            #expect(grid.isShown(by: frame), "frame \(index + 1) of the unzoom does not show every pane at its place: \(frame.panes)")
            #expect(frame.misfits.isEmpty, "frame \(index + 1): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
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
        let (shown, _) = try Self.frames(of: harness, after: Self.screens())
        for (index, frame) in shown.enumerated() {
            #expect(grid.isShown(by: frame), "frame \(index) shows another layout after the zoom was turned back: \(frame.panes)")
        }
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }
}
