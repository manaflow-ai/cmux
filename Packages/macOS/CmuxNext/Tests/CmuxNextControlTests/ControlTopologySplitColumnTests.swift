@testable import CmuxNextControl
import CmuxNextDaemon
import Testing

/// A pane's `column` on a screen whose panes stand side by side in one split tree, not in the daemon's
/// scrolling columns: the columns are the tree's side-by-side splits, as the window draws them. Every pane
/// of such a screen was column 0, so no pane was "right of the chat" there and each page a script opened in
/// an agent's workspace that no window showed made one more pane (the look at 066c7e8da37f: two pages, three
/// panes; Lawrence 2026-11-19: "agent chat that is on left, will open stuff to the right").
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ControlTopologySplitColumnTests {
    static func leaf(_ id: UInt64) -> LayoutNode { .leaf(PaneID(rawValue: id)) }

    static func split(_ direction: SplitDirection, _ a: LayoutNode, _ b: LayoutNode) -> LayoutNode {
        .split(id: nil, resourceID: nil, direction: direction, ratio: 0.5, a: a, b: b)
    }

    /// The topology of one workspace whose screen is `layout` (in `columns` when it scrolls), one terminal per pane.
    static func topology(_ layout: LayoutNode, columns: [ColumnSnapshot] = [], floating: [PaneID] = []) -> ControlTopology {
        let panes = (columns.isEmpty ? layout.paneIDs : columns.flatMap(\.layout.paneIDs)).map { id in
            PaneSnapshot(id: id, tabs: [TabSnapshot(surface: SurfaceID(rawValue: id.rawValue + 100))])
        }
        let floats = floating.map { FloatingPaneSnapshot(pane: $0, frame: .init(x: 0.2, y: 0.2, w: 0.5, h: 0.5)) }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, columns: columns, panes: panes, floating: floats)
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "agent", screens: [screen]),
        ]))
        return ControlTopology(store: store, selectedTab: { $0.tabs.first?.id })
    }

    /// Each pane's column, by its daemon handle.
    static func columns(_ topology: ControlTopology) -> [String: Int?] {
        Dictionary(uniqueKeysWithValues: topology.workspaces.flatMap(\.panes).map { ($0.handle, $0.column) })
    }

    @Test func aLonePaneIsColumnZero() {
        #expect(Self.columns(Self.topology(Self.leaf(1))) == ["1": 0])
    }

    @Test func twoPanesSideBySideAreTwoColumns() {
        let columns = Self.columns(Self.topology(Self.split(.right, Self.leaf(1), Self.leaf(2))))
        #expect(columns == ["1": 0, "2": 1], "\(columns)")
    }

    /// The tree the look left: a split right of the chat, then one more: chat | second page | first page.
    @Test func aSplitRightOfTheFirstPaneOfTwoMakesThreeColumns() {
        let tree = Self.split(.right, Self.split(.right, Self.leaf(1), Self.leaf(3)), Self.leaf(2))
        let columns = Self.columns(Self.topology(tree))
        #expect(columns == ["1": 0, "3": 1, "2": 2], "\(columns)")
    }

    @Test func panesStackedInTheRightHalfShareItsColumn() {
        let tree = Self.split(.right, Self.leaf(1), Self.split(.down, Self.leaf(2), Self.leaf(3)))
        let columns = Self.columns(Self.topology(tree))
        #expect(columns == ["1": 0, "2": 1, "3": 1], "\(columns)")
    }

    /// A pane below the chat is not on its right: a tree split down at its root is one column.
    @Test func aTreeSplitDownAtItsRootIsOneColumn() {
        let tree = Self.split(.down, Self.split(.right, Self.leaf(1), Self.leaf(2)), Self.leaf(3))
        let columns = Self.columns(Self.topology(tree))
        #expect(columns == ["1": 0, "2": 0, "3": 0], "\(columns)")
    }

    /// The daemon's scrolling columns keep their order; a column that holds panes side by side is as many columns.
    @Test func aScrollingColumnWithPanesSideBySideIsAsManyColumns() {
        let first = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 1, layout: Self.split(.right, Self.leaf(1), Self.leaf(2)))
        let second = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 0.5, layout: Self.split(.down, Self.leaf(3), Self.leaf(4)))
        let tree = Self.split(.right, first.layout, second.layout)
        let columns = Self.columns(Self.topology(tree, columns: [first, second]))
        #expect(columns == ["1": 0, "2": 1, "3": 2, "4": 2], "\(columns)")
    }

    /// A docked column is one column whatever it holds, and a top or bottom band is no column.
    @Test func aDockIsOneColumnAndABandIsNone() {
        let dock = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.3, layout: Self.split(.right, Self.leaf(1), Self.leaf(2)),
                                  dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat))
        let strip = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 1, layout: Self.leaf(3))
        let band = ColumnSnapshot(id: ColumnID(rawValue: 12), width: 1, layout: Self.leaf(4),
                                  dock: DockSnapshot(edge: .bottom, mode: .docked, role: nil))
        let tree = Self.split(.down, Self.split(.right, dock.layout, strip.layout), band.layout)
        let columns = Self.columns(Self.topology(tree, columns: [dock, strip, band]))
        #expect(columns == ["1": 0, "2": 0, "3": 1, "4": nil], "\(columns)")
    }

    /// A floating pane (the quick terminal) is a leaf the daemon keeps on the right of the pane it came from. It
    /// is shown above the layout, not beside that pane: it is no column of its own, in a tree and in a column.
    @Test func aFloatingPaneIsNoColumnRightOfItsPane() {
        let tree = Self.split(.right, Self.split(.right, Self.leaf(1), Self.leaf(9)), Self.leaf(2))
        let inTree = Self.columns(Self.topology(tree, floating: [9]))
        #expect(inTree == ["1": 0, "9": 0, "2": 1], "\(inTree)")
        let first = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 1, layout: Self.split(.right, Self.leaf(1), Self.leaf(9)))
        let second = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 0.5, layout: Self.leaf(2))
        let inColumns = Self.columns(Self.topology(Self.split(.right, first.layout, second.layout), columns: [first, second], floating: [9]))
        #expect(inColumns == ["1": 0, "9": 0, "2": 1], "\(inColumns)")
    }

    /// A floating pane above a split down leaves the panes below it side by side.
    @Test func aFloatingPaneAtTheTopOfTheTreeDoesNotHideTheColumnsBelowIt() {
        let tree = Self.split(.down, Self.leaf(9), Self.split(.right, Self.leaf(1), Self.leaf(2)))
        let columns = Self.columns(Self.topology(tree, floating: [9]))
        #expect(columns == ["9": 0, "1": 0, "2": 1], "\(columns)")
    }

    /// The whole path of the look: the chat's workspace, which no window shows, already has a page on the
    /// chat's right in one split tree. The next page opened with only the workspace named is a tab in that
    /// page's pane, not one more pane.
    @Test func aSecondPageOpenedInAnUnshownWorkspaceJoinsThePaneOfTheFirst() async throws {
        var topology = Self.topology(Self.split(.right, Self.leaf(1), Self.leaf(2)))
        let chat = try #require(topology.workspaces.first?.screens.first?.panes.first { $0.handle == "1" }?.tabs.first)
        let page = try #require(topology.workspaces.first?.screens.first?.panes.first { $0.handle == "2" }?.tabs.first)
        for pane in topology.workspaces[0].screens[0].panes.indices {
            for tab in topology.workspaces[0].screens[0].panes[pane].tabs.indices {
                let id = topology.workspaces[0].screens[0].panes[pane].tabs[tab].id
                topology.workspaces[0].screens[0].panes[pane].tabs[tab].kind = id == chat.id ? "conversation" : "browser"
                if id == chat.id { topology.workspaces[0].screens[0].panes[pane].tabs[tab].agentSessionID = "agent-1" }
            }
        }
        var snapshot = BrowserOpenSplitTests.snapshot()
        snapshot.topology.workspaces = topology.workspaces
        let request = try await ScriptedBrowserBesideChatTests().request(target: chat.id, in: snapshot)
        #expect(request.target == ControlTargetRef(kind: "tab", id: page.id), "\(String(describing: request.target))")
        #expect(!request.newColumnBeside)
        #expect(request.besideCaller)
    }
}
