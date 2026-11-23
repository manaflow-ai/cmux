import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A size that ends on a column whose pane is still opening (a pending split's stand-in) cannot go to the daemon: its
/// command would name a pane the daemon has not made. The app sends nothing and shows the daemon's sizes again, and
/// it says why with the pane-still-opening notice, as a request that names a stand-in does at the connection
/// (``PaneNotReady``). With no notice, the width a width preset or a divider's release set went back with no word.
@MainActor
@Suite(.closesItsWindows)
struct ResizeOfAPaneStillOpeningTests {
    @Test func oneEndedWidthForItsColumnShowsTheNoticeOnceAndGoesBack() throws {
        // c11's pane is a stand-in: its handle is in the range no daemon pane has (`ProvisionalPane`, from 1 << 62).
        let standIn: UInt64 = (1 << 62) + 7
        let screen = ScreenSnapshot(id: 1, layout: .leaf(DaemonPaneID(rawValue: 1)),
                                    columns: [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: 1))),
                                              ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: standIn)))],
                                    panes: [PaneSnapshot(id: DaemonPaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")]),
                                            PaneSnapshot(id: DaemonPaneID(rawValue: standIn), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])])
        let shown = try PaneCloseControllerTests.Shown(tree: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        defer { shown.end() }
        let content = try #require(shown.content)
        try #require(content.layoutModel.screens.first?.layout.columns.count == 2, "the stand-in column does not show")
        let before = content.layoutModel.screens.first?.layout.columns.map(\.width)
        let first = content.gestureTransactions.latest
        var notices: [String] = []
        shown.services.registry.refusalObserver = { reason, _ in notices.append(reason) }
        // The app's own route for an ended size: the model's intent reaches the content controller in the same turn.
        content.layoutModel.intentHandler = { [weak content] intent in content?.handle(intent) }

        // What a width preset's action and a divider's release end with: one width for the column.
        content.layoutModel.setColumnWidth(LayoutColumnID("column:11"), width: 0.75, transaction: .make(), phase: .ended)

        #expect(notices == [MiscHandlerStrings.paneNotReady], "the width went back with no pane-still-opening notice, or with more than one: \(notices)")
        #expect(content.layoutModel.screens.first?.layout.columns.map(\.width) == before, "the column kept a width the daemon never got")
        #expect(content.gestureTransactions.latest == first, "a width for a pane the daemon has not made took a daemon transaction")
    }

    /// A caller that collects an action's refusals in the action's turn (a control client's run of a width preset) gets
    /// the notice's text as its answer: the notice goes through the registry in the handler's turn, not a frame later.
    @Test func aCallerThatCollectsRefusalsInTheTurnGetsTheNoticeAsItsAnswer() throws {
        let standIn: UInt64 = (1 << 62) + 7 // a stand-in's handle, as above
        let screen = ScreenSnapshot(id: 1, layout: .leaf(DaemonPaneID(rawValue: 1)),
                                    columns: [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: 1))),
                                              ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: standIn)))],
                                    panes: [PaneSnapshot(id: DaemonPaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")]),
                                            PaneSnapshot(id: DaemonPaneID(rawValue: standIn), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])])
        let shown = try PaneCloseControllerTests.Shown(tree: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        defer { shown.end() }
        let content = try #require(shown.content)
        try #require(content.layoutModel.screens.first?.layout.columns.count == 2, "the stand-in column does not show")
        content.layoutModel.intentHandler = { [weak content] intent in content?.handle(intent) }
        let answer = shown.services.registry.capturingRefusal {
            content.layoutModel.setColumnWidth(LayoutColumnID("column:11"), width: 0.75, transaction: .make(), phase: .ended)
        }
        #expect(answer == MiscHandlerStrings.paneNotReady, "the caller's answer is not the pane-still-opening notice: \(answer ?? "none")")
    }

    /// The notice is for a pane still opening only. A width whose pane has no handle (the pane went away while the
    /// width was on its way) is not sent either, and it says nothing: no pane is opening.
    @Test func aWidthWhoseColumnsPaneIsGoneSaysNothing() throws {
        let shown = try PaneCloseControllerTests.Shown([ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)),
                                                        ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))])
        defer { shown.end() }
        let content = try #require(shown.content)
        let first = content.gestureTransactions.latest
        var notices: [String] = []
        shown.services.registry.refusalObserver = { reason, _ in notices.append(reason) }
        content.handle(.setColumnWidth(LayoutColumnID("column:11"), anyPane: "gone", width: 0.75, transaction: .make(), phase: .ended))
        #expect(notices.isEmpty, "a width for a pane that is gone showed a notice: \(notices)")
        #expect(content.gestureTransactions.latest == first, "a width for a pane that is gone took a daemon transaction")
    }
}
