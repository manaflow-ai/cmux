import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
import Foundation
import Testing

/// A column's only pane closing in the key's turn, through the real controller: the workspace's
/// content controller, its pane controllers, its focus coordinator and the daemon store's echoes.
///
/// - The focus a close moves is the focus reducer's pick (`layout.closeFocus`, the window's focus
///   history; close-focus.md), the same pane the daemon's tree without the pane would get.
/// - Overlapping closes under fit-screen: the shown widths are always what the closes still pending
///   leave, whatever order their echoes or refusals come in, and the widths go out once.
@MainActor struct PaneCloseControllerTests {
    private static func pane(_ id: UInt64) -> PaneSnapshot {
        PaneSnapshot(id: DaemonPaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id), title: "~")])
    }

    private static func tree(_ columns: [ColumnSnapshot]) -> DaemonTree {
        let ids = columns.flatMap { $0.layout.paneIDs }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(ids[0]), columns: columns, panes: ids.map { pane($0.rawValue) })
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    /// A split screen (no columns) with `layout`.
    private static func tree(_ layout: LayoutNode) -> DaemonTree {
        let screen = ScreenSnapshot(id: 1, layout: layout, panes: layout.paneIDs.map { pane($0.rawValue) })
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"pane-close-controller-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The shown workspace. Its pane controllers hold their services unowned: `end` releases the
    /// controller (and them) while the services live, and the tests keep no controller past it.
    final class Shown {
        let services: AppServices
        /// The content controller holds its window state unowned.
        let state: WindowState
        let window: NSWindow
        private(set) var content: WorkspaceContentController!
        /// Controllers a test closes through, as a close's command holds its controller until the reply.
        var held: [PaneController] = []
        var intents: [LayoutIntent] = []

        convenience init(_ columns: [ColumnSnapshot]) throws {
            try self.init(tree: PaneCloseControllerTests.tree(columns))
        }

        init(tree: DaemonTree) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.daemon.store
            store.connectionState = .connected(try PaneCloseControllerTests.connected())
            store.apply(snapshot: tree)
            let workspace = try #require(store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            content.layoutModel.newColumnWidthModeOverride = .fitScreen
            content.layoutModel.splitSizingOverride = .even
            content.applyCurrent()
            content.contentView.layoutSubtreeIfNeeded()
            content.layoutModel.intentHandler = { [weak self] in self?.intents.append($0) }
        }

        func end() {
            withExtendedLifetime((services, state)) {
                held = []
                content.teardown()
                window.close()
                content = nil
            }
        }

        func key(_ pane: UInt64) throws -> String { try #require(content.handles.paneIDs[DaemonPaneID(rawValue: pane)]).rawValue }
        func controller(_ pane: UInt64) throws -> PaneController { try #require(content.paneController(key: try key(pane))) }
        func focus(_ pane: UInt64) throws { content.focus.send(.focusPane(try key(pane), source: .programmatic)) }

        /// The daemon's tree, as its echo brings it.
        func echo(_ columns: [ColumnSnapshot]) {
            services.daemon.store.apply(snapshot: PaneCloseControllerTests.tree(columns))
            content.applyCurrent()
        }

        func echo(_ layout: LayoutNode) {
            services.daemon.store.apply(snapshot: PaneCloseControllerTests.tree(layout))
            content.applyCurrent()
        }

        /// The shown ratio of daemon split `split`.
        func ratio(_ split: UInt64) -> Double? {
            content.layoutModel.screens.first?.layout.ratio(of: LayoutSplitID("split:\(split)"))
        }

        var ratioIntents: [String] {
            intents.compactMap { intent in
                guard case let .setSplitRatio(split, ratio, _, .ended) = intent else { return nil }
                return "\(split.rawValue)=\(String(format: "%.4f", ratio))"
            }
        }

        func width(_ column: UInt64) -> Double? {
            content.layoutModel.screens.first?.layout.columns.first { $0.id == LayoutColumnID("column:\(column)") }?.width
        }

        var widthIntents: [String] {
            intents.compactMap { intent in
                guard case let .setColumnWidth(column, _, width, _, .ended) = intent else { return nil }
                return "\(column.rawValue)=\(width)"
            }
        }
    }

    // MARK: Focus

    /// Close-focus.md: the right column's only pane closes, so its focus goes to the nearest column on
    /// the left, entering it at its most recently focused pane (p3), not at its first (p1).
    @Test func theFocusGoesToTheLeftColumnsMostRecentPane() throws {
        let shown = try Shown([ColumnSnapshot(id: 10, width: 0.5, layout: .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(1), b: .leaf(3))),
                               ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))])
        defer { shown.end() }
        try shown.focus(3)
        try shown.focus(2)
        _ = try #require(try shown.controller(2).showPaneClose(), "the right column's only pane waited for the daemon's tree")
        #expect(shown.content.focus.state.pane == (try shown.key(3)), "focus: \(String(describing: shown.content.focus.state.pane))")
        #expect(shown.content.layoutModel.focusedPane?.rawValue == (try shown.key(3)))
        shown.echo([ColumnSnapshot(id: 10, width: 0.5, layout: .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(1), b: .leaf(3)))])
        #expect(shown.content.focus.state.pane == (try shown.key(3)), "the echo moved the focus")
    }

    /// `layout.closeFocus`: the previous neighbour (default) or the most recently focused pane.
    @Test(arguments: zip([CloseFocusPolicy.previousNeighbor, .mostRecent], [UInt64(1), 3]))
    func theFocusFollowsTheCloseFocusSetting(policy: CloseFocusPolicy, expected: UInt64) throws {
        let columns = [ColumnSnapshot(id: 10, width: 0.34, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.33, layout: .leaf(2)),
                       ColumnSnapshot(id: 12, width: 0.33, layout: .leaf(3))]
        let shown = try Shown(columns)
        defer { shown.end() }
        shown.content.focus.closeFocus = { policy }
        try shown.focus(3)
        try shown.focus(2)
        _ = try #require(try shown.controller(2).showPaneClose())
        #expect(shown.content.focus.state.pane == (try shown.key(expected)), "\(policy): \(String(describing: shown.content.focus.state.pane))")
        #expect(shown.content.layoutModel.focusedPane?.rawValue == (try shown.key(expected)))
        shown.echo([columns[0], columns[2]])
        #expect(shown.content.focus.state.pane == (try shown.key(expected)), "the echo moved the focus")
    }

    /// Columns A, B, C with C focused: B closes in the background (a `pane.close` of an unfocused
    /// pane), then C before B's echo. The focus goes to A, which still shows, never to the hidden B,
    /// and the coordinator and the layout agree on it through both echoes.
    @Test func aBackgroundCloseLeavesNoHiddenPaneForTheNextClosesFocus() throws {
        let columns = [ColumnSnapshot(id: 10, width: 0.34, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.33, layout: .leaf(2)),
                       ColumnSnapshot(id: 12, width: 0.33, layout: .leaf(3))]
        let shown = try Shown(columns)
        defer { shown.end() }
        try shown.focus(3)
        _ = try #require(try shown.controller(2).showPaneClose(), "B did not close in the key's turn")
        #expect(shown.content.focus.state.pane == (try shown.key(3)), "a background close moved the focus")
        #expect(!shown.content.focus.state.topology.contains(pane: try shown.key(2)), "the coordinator still holds the hidden B")
        _ = try #require(try shown.controller(3).showPaneClose(), "C did not close in the key's turn")
        #expect(shown.content.focus.state.pane == (try shown.key(1)), "focus: \(String(describing: shown.content.focus.state.pane))")
        #expect(shown.content.layoutModel.focusedPane?.rawValue == (try shown.key(1)),
                "layout focus: \(String(describing: shown.content.layoutModel.focusedPane))")
        shown.echo([columns[0], columns[2]])
        #expect(shown.content.focus.state.pane == (try shown.key(1)))
        shown.echo([columns[0]])
        #expect(shown.content.focus.state.pane == (try shown.key(1)))
        #expect(shown.content.layoutModel.focusedPane?.rawValue == (try shown.key(1)))
    }

    // MARK: Overlapping closes

    private static let dock = ColumnSnapshot(id: 10, width: 0.3, layout: .leaf(1), dock: DockSnapshot(edge: .left, mode: .docked))
    private static let third = 1.0 / 3
    private static let strip = [dock, ColumnSnapshot(id: 11, width: third, layout: .leaf(2)), ColumnSnapshot(id: 12, width: third, layout: .leaf(3)),
                                ColumnSnapshot(id: 13, width: third, layout: .leaf(4))]

    /// The chat docked left and three columns at a third: c13, then c12, close before either reply.
    private static func closingTwo() throws -> (Shown, first: PendingPaneClose, second: PendingPaneClose) {
        let shown = try Shown(strip)
        let first = try #require(try shown.controller(4).showPaneClose())
        shown.held = [try shown.controller(3)]
        let second = try #require(shown.held[0].showPaneClose())
        #expect(shown.width(11) == 1, "c11 does not take the viewport: \(String(describing: shown.width(11)))")
        return (shown, first, second)
    }

    @Test func overlappingClosesKeepTheirWidthsThroughOrderedEchoes() throws {
        let (shown, _, _) = try Self.closingTwo()
        defer { shown.end() }
        shown.echo(Array(Self.strip.prefix(3)))
        #expect(shown.width(11) == 1, "the first echo resized c11 to \(String(describing: shown.width(11)))")
        #expect(shown.widthIntents.isEmpty, "sent \(shown.widthIntents) while a close was pending")
        shown.echo(Array(Self.strip.prefix(2)))
        #expect(shown.width(11) == 1)
        #expect(shown.widthIntents == ["column:11=1.0"], "sent \(shown.widthIntents)")
    }

    @Test func overlappingClosesKeepTheirWidthsThroughOutOfOrderEchoes() throws {
        let (shown, _, _) = try Self.closingTwo()
        defer { shown.end() }
        shown.echo([Self.strip[0], Self.strip[1], Self.strip[3]])
        #expect(shown.width(11) == 1, "the second close's echo resized c11 to \(String(describing: shown.width(11)))")
        #expect(shown.widthIntents.isEmpty, "sent \(shown.widthIntents) while a close was pending")
        shown.echo(Array(Self.strip.prefix(2)))
        #expect(shown.width(11) == 1)
        #expect(shown.widthIntents == ["column:11=1.0"], "sent \(shown.widthIntents)")
    }

    /// The second close refused before any reply: c12 comes back at the half the first close leaves.
    @Test func aRefusedSecondCloseBringsBackTheFirstClosesWidths() throws {
        let (shown, _, second) = try Self.closingTwo()
        defer { shown.end() }
        shown.held[0].finishPaneClose(second, failed: true)
        #expect(shown.width(11) == 0.5 && shown.width(12) == 0.5, "c11 \(String(describing: shown.width(11))), c12 \(String(describing: shown.width(12)))")
        #expect(shown.width(13) == nil)
        #expect(shown.widthIntents.isEmpty)
        shown.echo(Array(Self.strip.prefix(3)))
        #expect(shown.width(11) == 0.5 && shown.width(12) == 0.5)
        #expect(shown.widthIntents.sorted() == ["column:11=0.5", "column:12=0.5"], "sent \(shown.widthIntents)")
    }

    /// The first close landed, then the second is refused: the first close's widths go out then.
    @Test func aSecondCloseRefusedAfterTheFirstLandedSendsTheFirstClosesWidths() throws {
        let (shown, _, second) = try Self.closingTwo()
        defer { shown.end() }
        shown.echo(Array(Self.strip.prefix(3)))
        shown.held[0].finishPaneClose(second, failed: true)
        #expect(shown.width(11) == 0.5 && shown.width(12) == 0.5, "c11 \(String(describing: shown.width(11))), c12 \(String(describing: shown.width(12)))")
        #expect(shown.widthIntents.sorted() == ["column:11=0.5", "column:12=0.5"], "sent \(shown.widthIntents)")
    }

    /// c13 closes and its echo lands, so its widths (c11 = c12 = 0.5) go out; before the daemon
    /// acknowledges them c12 closes. c11 takes the viewport in that key's turn, not after the older
    /// widths' reply, and keeps it through the acknowledgement and c12's echo; its width goes once.
    @Test func aCloseBeforeTheLastClosesWidthsAreAcknowledgedOwnsTheWidths() throws {
        let shown = try Shown(Self.strip)
        defer { shown.end() }
        _ = try #require(try shown.controller(4).showPaneClose())
        shown.echo(Array(Self.strip.prefix(3)))
        #expect(shown.width(11) == 0.5 && shown.width(12) == 0.5)
        #expect(shown.widthIntents.sorted() == ["column:11=0.5", "column:12=0.5"], "sent \(shown.widthIntents)")
        shown.held = [try shown.controller(3)]
        _ = try #require(shown.held[0].showPaneClose())
        #expect(shown.width(11) == 1, "c11 waits for the older widths' reply: \(String(describing: shown.width(11)))")
        let half = [Self.dock, ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2)), ColumnSnapshot(id: 12, width: 0.5, layout: .leaf(3))]
        shown.echo(half)
        #expect(shown.width(11) == 1, "the acknowledgement resized c11 to \(String(describing: shown.width(11)))")
        shown.echo(Array(half.prefix(2)))
        #expect(shown.width(11) == 1)
        #expect(shown.widthIntents.sorted() == ["column:11=0.5", "column:11=1.0", "column:12=0.5"], "sent \(shown.widthIntents)")
    }

    // MARK: Overlapping closes in one split chain

    /// `panes` in one horizontal chain, split `sN` before pane N at `ratios[N-1]`; even by default
    /// (p1 | p2 | p3 | p4: s1 1/4, s2 1/3, s3 1/2). The daemon's tree after a close keeps the
    /// surviving splits' ratios (the closed pane's sibling takes its place).
    private static func chain(_ panes: [UInt64], _ ratios: [Double]? = nil) -> LayoutNode {
        guard panes.count > 1 else { return .leaf(DaemonPaneID(rawValue: panes[0])) }
        let ratio = ratios?.first ?? 1.0 / Double(panes.count)
        return .split(id: DaemonSplitID(rawValue: panes[0]), resourceID: nil, direction: .right, ratio: ratio,
                      a: .leaf(DaemonPaneID(rawValue: panes[0])), b: chain(Array(panes.dropFirst()), ratios.map { Array($0.dropFirst()) }))
    }

    private static func near(_ value: Double?, _ target: Double) -> Bool { value.map { abs($0 - target) < 1e-6 } ?? false }

    /// p4 closes, then p3, before either reply: the chain shows p1 | p2 at halves. p3's close is
    /// refused: p4's close is still pending, so the chain shows its sizes (s1 1/3, s2 1/2), not the
    /// daemon's quarters, until p4's echo; then they go to the daemon once.
    @Test func aRefusedLaterCloseInOneChainKeepsTheEarlierClosesRatios() throws {
        let shown = try Shown(tree: Self.tree(Self.chain([1, 2, 3, 4])))
        defer { shown.end() }
        _ = try #require(try shown.controller(4).showPaneClose())
        #expect(Self.near(shown.ratio(1), 1.0 / 3) && Self.near(shown.ratio(2), 0.5), "s1 \(String(describing: shown.ratio(1))), s2 \(String(describing: shown.ratio(2)))")
        shown.held = [try shown.controller(3)]
        let second = try #require(shown.held[0].showPaneClose())
        #expect(Self.near(shown.ratio(1), 0.5), "s1 \(String(describing: shown.ratio(1)))")
        shown.held[0].finishPaneClose(second, failed: true)
        #expect(Self.near(shown.ratio(1), 1.0 / 3) && Self.near(shown.ratio(2), 0.5),
                "the refusal lost p4's close sizing: s1 \(String(describing: shown.ratio(1))), s2 \(String(describing: shown.ratio(2)))")
        #expect(shown.ratioIntents.isEmpty, "sent \(shown.ratioIntents)")
        shown.echo(Self.chain([1, 2, 3], [0.25, 1.0 / 3]))
        #expect(Self.near(shown.ratio(1), 1.0 / 3) && Self.near(shown.ratio(2), 0.5), "s1 \(String(describing: shown.ratio(1))), s2 \(String(describing: shown.ratio(2)))")
        #expect(shown.ratioIntents.sorted() == ["split:1=0.3333", "split:2=0.5000"], "sent \(shown.ratioIntents)")
    }

    /// The same two closes, both landing in ONE daemon snapshot (each closed pane the other's
    /// sibling): the chain ends even and its ratio goes once.
    @Test func overlappingClosesInOneChainLandingInOneSnapshotEndEven() throws {
        let shown = try Shown(tree: Self.tree(Self.chain([1, 2, 3, 4])))
        defer { shown.end() }
        _ = try #require(try shown.controller(4).showPaneClose())
        _ = try #require(try shown.controller(3).showPaneClose())
        shown.echo(Self.chain([1, 2], [0.25]))
        #expect(Self.near(shown.ratio(1), 0.5), "s1 \(String(describing: shown.ratio(1)))")
        #expect(shown.ratioIntents == ["split:1=0.5000"], "sent \(shown.ratioIntents)")
    }

    /// The same two closes, both accepted, their echoes in order: p1 | p2 stay at halves through
    /// both, and the ratio goes once, after the last echo.
    @Test func overlappingClosesInOneChainKeepTheirRatiosThroughTheirEchoes() throws {
        let shown = try Shown(tree: Self.tree(Self.chain([1, 2, 3, 4])))
        defer { shown.end() }
        _ = try #require(try shown.controller(4).showPaneClose())
        _ = try #require(try shown.controller(3).showPaneClose())
        shown.echo(Self.chain([1, 2, 3], [0.25, 1.0 / 3]))
        #expect(Self.near(shown.ratio(1), 0.5), "the first echo resized s1 to \(String(describing: shown.ratio(1)))")
        #expect(shown.ratioIntents.isEmpty, "sent \(shown.ratioIntents) while a close was pending")
        shown.echo(Self.chain([1, 2], [0.25]))
        #expect(Self.near(shown.ratio(1), 0.5))
        #expect(shown.ratioIntents == ["split:1=0.5000"], "sent \(shown.ratioIntents)")
    }

    /// The first close refused while the second is pending: c13 comes back, and c11 and c13 share.
    @Test func aRefusedFirstCloseLeavesTheSecondClosesWidths() throws {
        let (shown, first, _) = try Self.closingTwo()
        defer { shown.end() }
        shown.content.layoutModel.cancelPaneClose(first)
        #expect(shown.width(11) == 0.5 && shown.width(13) == 0.5 && shown.width(12) == nil,
                "c11 \(String(describing: shown.width(11))), c13 \(String(describing: shown.width(13)))")
        #expect(shown.widthIntents.isEmpty)
    }
}
