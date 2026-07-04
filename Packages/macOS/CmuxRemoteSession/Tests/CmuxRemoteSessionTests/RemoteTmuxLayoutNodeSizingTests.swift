import Testing
@testable import CmuxRemoteSession

/// Regression coverage for remote-tmux mirror multi-pane client sizing
/// (https://github.com/manaflow-ai/cmux/issues/7053): after an in-tab split, the
/// mirror must size the tmux client from each pane's ON-SCREEN rendered grid —
/// which already excludes cmux's per-pane header (24pt) — not from the raw
/// container pixels / tmux's claimed pane geometry. Reporting the header-inclusive
/// height told tmux the panes were taller than the visible terminal area, so
/// alt-screen TUIs (lazygit, htop) drew past the top and clipped their first rows.
///
/// These exercise the real composition
/// (``RemoteTmuxLayoutNode/composedClientGrid(paneGrid:)``) over layout trees
/// parsed by the real ``RemoteTmuxRawLayoutParser`` — behavior, not source shape.
///
@Suite("remote tmux layout node sizing")
struct RemoteTmuxLayoutNodeSizingTests {

    /// A single pane composes to exactly its own rendered grid (the leaf case —
    /// the same value the single-pane path reports via `renderedGridCells()`).
    @Test
    func singlePaneComposesToItsRenderedGrid() throws {
        let node = try #require(RemoteTmuxRawLayoutParser().parse("f00d,147x85,0,0,0"))
        let grid = try #require(node.composedClientGrid { _ in (columns: 147, rows: 85) })
        #expect(grid.columns == 147)
        #expect(grid.rows == 85)
    }

    /// THE BUG: two side-by-side panes, each rendering 83 rows because a 24pt
    /// per-pane header eats ~2 rows off the tab's 85-row height. The composed
    /// client must report 83 rows (what is visible), NOT 85 (the container height /
    /// tmux's claimed pane height), and 148 columns (74 + 73 + one divider cell).
    @Test
    func sideBySideSplitReportsHeaderCorrectedHeight() throws {
        // 148x85 { 74x85 @0 pane %0 | 73x85 @75 pane %1 }  (74 + 1 divider + 73 = 148)
        let node = try #require(RemoteTmuxRawLayoutParser().parse("1a2b,148x85,0,0{74x85,0,0,0,73x85,75,0,1}"))
        let rendered: [Int: (columns: Int, rows: Int)] = [0: (74, 83), 1: (73, 83)]
        let grid = try #require(node.composedClientGrid { rendered[$0] })
        #expect(grid.columns == 148)   // 74 + 73 + 1 divider column
        #expect(grid.rows == 83)       // header-corrected, not the container's 85
    }

    /// The perpendicular axis takes the smallest visible capacity: tmux gives
    /// side-by-side siblings the same height, so reporting the taller sibling would
    /// make the shorter visible pane clip alt-screen content.
    @Test
    func sideBySideSplitUsesShortestVisibleHeight() throws {
        let node = try #require(RemoteTmuxRawLayoutParser().parse("1a2b,148x85,0,0{74x85,0,0,0,73x85,75,0,1}"))
        let grid = try #require(node.composedClientGrid { $0 == 0 ? (columns: 74, rows: 83) : (columns: 73, rows: 80) })
        #expect(grid.columns == 148)
        #expect(grid.rows == 80)       // min(83, 80)
    }

    /// A stacked split sums heights (+1 divider row) and uses the shared visible
    /// width — the vertical analogue. Each pane still loses its header rows, so
    /// the sum stays header-corrected.
    @Test
    func stackedSplitSumsHeaderCorrectedHeights() throws {
        // 80x50 [ 80x25 @0 pane %0 / 80x24 @26 pane %1 ]  (25 + 1 divider + 24 = 50)
        let node = try #require(RemoteTmuxRawLayoutParser().parse("1a2b,80x50,0,0[80x25,0,0,0,80x24,0,26,1]"))
        let grid = try #require(node.composedClientGrid { $0 == 0 ? (columns: 80, rows: 23) : (columns: 80, rows: 22) })
        #expect(grid.columns == 80)
        #expect(grid.rows == 23 + 22 + 1)   // 46: header-corrected sum + 1 divider row
    }

    /// Nested rendered grids can have different visible heights on sibling
    /// branches because a stacked branch contains two pane headers while a leaf
    /// branch contains one. The composed client must fit the shorter nested branch.
    @Test
    func nestedSideBySideSplitUsesShortestRenderedBranchHeight() throws {
        let node = try #require(
            RemoteTmuxRawLayoutParser().parse("f92f,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}")
        )
        let rendered: [Int: (columns: Int, rows: Int)] = [
            4: (60, 38),
            5: (59, 18),
            8: (59, 17)
        ]
        let grid = try #require(node.composedClientGrid { rendered[$0] })
        #expect(grid.columns == 120)
        #expect(grid.rows == 18 + 17 + 1)   // 36: nested stacked branch capacity
    }

    /// tmux's own layout invariant: composing each leaf's CLAIMED `(width, height)`
    /// reproduces the root's dimensions exactly, on both axes and through nesting.
    /// This pins the divider math (one cell between adjacent panes) to tmux's model,
    /// so the composed client lands on the same grid tmux reports for the layout.
    @Test
    func composingClaimedGeometryReproducesRoot() throws {
        // Nested: { pane4 60x40 | [ pane5 59x20 / pane8 59x19 ] 59x40 } — the parser's
        // own doc example. (60 + 1 + 59 = 120 across; 20 + 1 + 19 = 40 down.)
        let node = try #require(
            RemoteTmuxRawLayoutParser().parse("f92f,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}")
        )
        let claimed: [Int: (columns: Int, rows: Int)] = [4: (60, 40), 5: (59, 20), 8: (59, 19)]
        let grid = try #require(node.composedClientGrid { claimed[$0] })
        #expect(grid.columns == node.width)   // 120
        #expect(grid.rows == node.height)     // 40
    }

    /// A not-yet-live leaf (no rendered grid) makes the whole composition `nil`, so
    /// the caller waits for a surface readiness/grid signal instead of sending a
    /// short client size that would reflow the remote to a partial layout.
    @Test
    func notYetLivePanePropagatesNil() throws {
        let node = try #require(
            RemoteTmuxRawLayoutParser().parse("f92f,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}")
        )
        let grid = node.composedClientGrid { paneId in paneId == 8 ? nil : (columns: 10, rows: 10) }
        #expect(grid == nil)
    }
}
