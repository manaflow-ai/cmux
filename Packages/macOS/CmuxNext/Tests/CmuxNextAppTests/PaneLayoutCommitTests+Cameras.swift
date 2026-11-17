import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneLayoutCommitTests`, the closes that move a camera: a close in a scrolled strip of columns or in a column whose
/// rows scroll. The camera's new place is part of the close, so it shows in the frame that shows the close.
extension PaneLayoutCommitTests {
    /// A close that resizes no pane, by the key's own close and the key's sync, while the strip's camera still moves (the
    /// reveal of the column the focus went to). The key's turn presents nothing, so it changes nothing that shows: the
    /// closed pane and every other pane show as they did until the frame tick that places the panes. That tick hides
    /// the closed pane, and its teardown follows that tick's commit.
    @Test func aKeysCloseWhileACameraMovesHidesNothingBeforeTheFrameThatPlacesThePanes() throws {
        let harness = Harness(Self.strip([1, 2, 3, 4]), focused: "p1", holds: false) { $0.rowsEnabledOverride = true }
        defer { harness.window.closeAfterTest() }
        // The columns that stay keep their widths (no setting of the Mac the test runs on resizes them).
        harness.model.newColumnWidthModeOverride = .matchCurrent
        var afterCommit: [@MainActor () -> Void] = []
        harness.root.context.afterCommit = { afterCommit.append($0) }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        // The focus goes to the last column: the strip's camera starts its way there, and no frame has stepped it.
        harness.model.focus("p4", notify: false)
        harness.root.syncWithModel()
        try #require(screen.hasMotion, "set-up: the strip's camera is not on its way to the focused column")
        let closed = try #require(harness.root.context.hosts["p2"])
        let before = Self.shown(screen)

        _ = try #require(harness.model.showPaneClose("p2"), "set-up: the model left p2's close to the daemon's tree")
        harness.root.syncWithModelForNextFrame()
        #expect(!closed.isHidden && Self.same(Self.shown(screen), before),
                "the key's turn changed what shows before the frame that places the panes: p2 hidden \(closed.isHidden), \(Self.shown(screen).panes)")
        // What the key's turn put after its own commit runs now: a teardown queued there is the key's turn's too.
        let queued = afterCommit
        afterCommit = []
        for item in queued { item() }
        #expect(harness.provider.released.isEmpty, "the key's turn tore the closed pane down, or queued its teardown for after its own commit")

        _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
        #expect(closed.isHidden, "the frame tick that places the panes still shows the closed pane")
        #expect(Set(Self.shown(screen).panes.keys) == ["p1", "p3", "p4"], "that frame does not show the panes that stay: \(Self.shown(screen).panes.keys)")
        #expect(harness.provider.released.isEmpty, "the frame that shows the close tore the closed pane down")
        let work = afterCommit
        afterCommit = []
        for item in work { item() }
        #expect(harness.provider.released == ["p2"], "the closed pane was not torn down after that frame's commit: \(harness.provider.released)")
    }

    // MARK: A close that moves a camera

    /// One full-width column of rows (`heights` in permille of the column), as the daemon sends it: the rows, and the
    /// chain of vertical splits that holds every pane, folded as the daemon folds it (the split of row k joins the rows
    /// above it, its `a`, with row k, its `b`; its ratio is the heights above over the heights through). Rows of more
    /// than 1000 in all overflow, and the column scrolls.
    static func rows(_ heights: [Int]) -> [LayoutScreen] {
        let rows = heights.enumerated().map { index, height in
            LayoutRow(id: RowID("r\(index + 1)"), height: height, root: .leaf(PaneID("p\(index + 1)")))
        }
        var chain = rows[0].root, above = Double(heights[0])
        for (row, height) in zip(rows, heights).dropFirst() {
            chain = .split(SplitID("v\(row.id.rawValue)"), axis: .vertical, ratio: above / (above + Double(height)), a: chain, b: row.root)
            above += Double(height)
        }
        return [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c1", width: 1, root: chain, rows: rows)]))]
    }

    /// A strip of the columns `numbers` (column `cN` holds pane `pN`), each half the screen wide: more than two scroll.
    static func strip(_ numbers: [Int]) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .columns(numbers.map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.5, root: .leaf(PaneID("p\($0)"))) }))]
    }

    struct CameraClose: CustomTestStringConvertible, Sendable {
        let name: String
        var testDescription: String { name }
    }

    nonisolated static let cameraCloses = [
        CameraClose(name: "the last row, and the rest fit their column"), CameraClose(name: "the last row, and the rows still overflow"),
        CameraClose(name: "the last column of a scrolled strip"), CameraClose(name: "a middle column of a strip scrolled to its end"),
    ]

    /// The layout before the close with the pane that has the focus in it (the pane at its end, so its camera rests at
    /// its end), and the layout after the close with the pane the close's topology focuses.
    static func layouts(of close: CameraClose) -> (before: [LayoutScreen], focused: PaneID, after: [LayoutScreen], focus: PaneID) {
        switch close.name {
        case "the last row, and the rest fit their column": (rows([500, 500, 500]), "p3", rows([500, 500]), "p2")
        case "the last row, and the rows still overflow": (rows([400, 400, 400, 400]), "p4", rows([400, 400, 400]), "p3")
        case "the last column of a scrolled strip": (strip([1, 2, 3]), "p3", strip([1, 2]), "p2")
        default: (strip([1, 2, 3, 4]), "p4", strip([1, 2, 4]), "p4")
        }
    }

    /// A close that leaves a scrolled camera with less to show (the last row of a column whose rows overflow, the last
    /// column of a scrolled strip, a column before the last one): the camera's new place is part of the close. Each
    /// frame shows what the screen showed before the close, or the layout after it with its camera at rest, with
    /// nothing between: no frame shows the panes that stay on their way to their places, beside the ground of the pane
    /// that left. Each close runs both ways it reaches the layout: by the daemon's echo (its tree, then the focus), and
    /// by the key's own close (`LayoutModel.showPaneClose`: the model takes the pane out, and moves the focus when the
    /// pane had it, in the key's turn). The layout the model then holds is the oracle of both.
    @Test(arguments: cameraCloses, [false, true])
    func aCloseThatMovesACameraShowsInOneFrame(_ close: CameraClose, byKey: Bool) throws {
        let change = Self.layouts(of: close)
        let harness = Harness(change.before, focused: change.focused, holds: false) { $0.rowsEnabledOverride = true }
        defer { harness.window.closeAfterTest() }
        // The columns that stay keep their widths after the key's close (no setting of the Mac the test runs on
        // resizes them), as the daemon's tree of that case has them.
        harness.model.newColumnWidthModeOverride = .matchCurrent
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let camera = max(screen.rowScrolls["c1"]?.state.spring.value ?? 0, screen.scroll.value)
        try #require(camera > 100, "set-up: the camera is not scrolled to the pane that closes (\(camera))")
        let before = Self.shown(screen)

        if byKey {
            // The key's order for a close: the model takes out the pane the layout after the close no longer has, and
            // gives the focus to its successor when it had it, in one turn. The view then reads both in one sync.
            let panesAfter = change.after[0].layout.panes
            let closing = try #require(change.before[0].layout.panes.first(where: { !panesAfter.contains($0) }))
            _ = try #require(harness.model.showPaneClose(closing), "set-up: the model left \(closing)'s close to the daemon's tree")
            try #require(harness.model.screens[0].layout.panes == panesAfter && harness.model.focusedPane == change.focus,
                         "set-up: the key's close leaves other panes or another focus than the daemon's tree: \(harness.model.screens[0].layout.panes)")
        } else {
            // The order of the daemon's echo of a close: its tree, then the focus the close's topology lands.
            harness.model.apply(screens: change.after)
        }
        // At rest the camera shows the end of what the layout still has: all of it, when it fits.
        let after = Rest(harness.model.screens, in: screen, style: harness.root.context.style, camerasAtEnd: true)
        if byKey {
            // The app's key syncs for the next frame (`PaneController.showPaneClose`): its turn presents only what no
            // frame tick will.
            harness.root.syncWithModelForNextFrame()
        } else {
            harness.root.syncWithModel()
            harness.model.focus(change.focus, notify: false)
            harness.root.syncWithModel()
        }
        var shown = [Self.shown(screen)]
        for _ in 0..<Self.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Self.shown(screen))
        }

        var reached = false
        for (index, frame) in shown.enumerated() {
            if after.isShown(by: frame) {
                reached = true
            } else {
                #expect(!reached, "frame \(index) leaves the layout after the close: \(frame.panes)")
                #expect(Self.same(frame, before), "frame \(index) shows neither what showed before the close nor the layout after it: \(frame.panes); after \(after.panes)")
            }
        }
        #expect(after.isShown(by: shown[1]), "the first display frame after the close does not show its layout at rest: \(shown[1].panes)")
    }

    /// Two closes of that kind, the second in the turn of the first and one display frame after it (a held close key):
    /// each frame shows what the screen showed before them, or the layout after one of them with its camera at rest, in
    /// their order, and the last one shows the layout after both. In the third kind the second close leaves rows that
    /// fit their column: they fill it, so that close resizes them and drops the camera in one frame.
    @Test(arguments: ["rows", "rows that fit after the second close", "columns"], [0, 1])
    func twoClosesThatMoveACameraShowOnlyWholeLayouts(of kind: String, framesBetween: Int) throws {
        let layouts: [[LayoutScreen]] = switch kind {
        case "rows": [Self.rows([400, 400, 400, 400, 400]), Self.rows([400, 400, 400, 400]), Self.rows([400, 400, 400])]
        case "rows that fit after the second close": [Self.rows([400, 400, 400, 400]), Self.rows([400, 400, 400]), Self.rows([400, 400])]
        default: [Self.strip([1, 2, 3, 4, 5]), Self.strip([1, 2, 3, 4]), Self.strip([1, 2, 3])]
        }
        // The focus is in each layout's last pane: the pane that closes next, then the pane its close's topology focuses.
        let focuses = layouts.compactMap { $0[0].layout.panes.last }
        let harness = Harness(layouts[0], focused: focuses[0], holds: false) { $0.rowsEnabledOverride = true }
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let camera = max(screen.rowScrolls["c1"]?.state.spring.value ?? 0, screen.scroll.value)
        try #require(camera > 100, "set-up: the camera is not scrolled to the pane that closes (\(camera))")
        let before = Self.shown(screen)

        var states: [Rest] = [], shown: [Frame] = []
        for (index, focus) in focuses.dropFirst().enumerated() {
            // The order of the daemon's echo of a close: its tree, then the focus the close's topology lands.
            harness.model.apply(screens: layouts[index + 1])
            states.append(Rest(harness.model.screens, in: screen, style: harness.root.context.style, camerasAtEnd: true))
            harness.root.syncWithModel()
            harness.model.focus(focus, notify: false)
            harness.root.syncWithModel()
            shown.append(Self.shown(screen))
            for _ in 0..<(index == 0 ? framesBetween : Self.frames) {
                _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
                shown.append(Self.shown(screen))
            }
        }

        // The newest layout a frame showed: none yet (what showed before the closes), then the first, then the second.
        var reached: Int?
        for (index, frame) in shown.enumerated() {
            if let next = ((reached ?? 0)..<states.count).first(where: { states[$0].isShown(by: frame) }) {
                reached = next
            } else {
                #expect(reached == nil && Self.same(frame, before),
                        "frame \(index) shows no whole layout of the two closes, or one after a later one: \(frame.panes)")
            }
        }
        #expect(states[1].isShown(by: shown[shown.count - 1]), "the last frame is not the layout after both closes at rest: \(shown[shown.count - 1].panes)")
    }
}
