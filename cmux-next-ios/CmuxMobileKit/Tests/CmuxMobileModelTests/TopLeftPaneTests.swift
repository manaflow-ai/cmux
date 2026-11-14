import Foundation
import Testing
@testable import CmuxMobileModel

/// A workspace opens on its layout's leftmost, topmost pane's active tab (user 2026-11-11):
/// `WorkspaceLayout.Screen.topLeftPane` reads the pane at the top-left corner as the Mac
/// draws the screen.
@Suite struct TopLeftPaneTests {
    typealias Layout = WorkspaceLayout
    typealias Pane = WorkspaceLayout.Pane
    typealias Column = WorkspaceLayout.Column

    func screen(_ panes: [Pane], root: Layout.Node? = nil, columns: [Column] = []) -> Layout.Screen {
        Layout.Screen(id: 1, isActive: true, panes: panes, root: root, columns: columns)
    }

    func panes(_ ids: Int...) -> [Pane] { ids.map { Pane(id: $0, tabIDs: ["t\($0)"], activeTabID: "t\($0)") } }

    @Test func aSidebySideSplitOpensOnItsLeftPane() {
        // Listed right first (the Mac's focused pane first): the left one still wins.
        let s = screen(panes(2, 1), root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))
        #expect(s.topLeftPane?.id == 1)
    }

    @Test func aStackedSplitOpensOnItsTopPane() {
        let s = screen(panes(2, 1), root: .split(id: 9, axis: .vertical, ratio: 0.3, first: .pane(1), second: .pane(2)))
        #expect(s.topLeftPane?.id == 1)
    }

    @Test func aLeftColumnOfRowsOpensOnItsTopRow() {
        // (1 over 2) | (3 over 4)
        let left = Layout.Node.split(id: 10, axis: .vertical, ratio: 0.5, first: .pane(1), second: .pane(2))
        let right = Layout.Node.split(id: 11, axis: .vertical, ratio: 0.5, first: .pane(3), second: .pane(4))
        let s = screen(panes(4, 3, 2, 1), root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: left, second: right))
        #expect(s.topLeftPane?.id == 1)
        // A full-width top pane over a side by side pair: the top one.
        let bottom = Layout.Node.split(id: 12, axis: .horizontal, ratio: 0.5, first: .pane(2), second: .pane(3))
        let t = screen(panes(3, 2, 1), root: .split(id: 9, axis: .vertical, ratio: 0.4, first: .pane(1), second: bottom))
        #expect(t.topLeftPane?.id == 1)
    }

    @Test func aStackCountsItsShownPane() {
        let s = screen(panes(1, 2, 3), root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .stack([1, 2], expanded: 2), second: .pane(3)))
        #expect(s.topLeftPane?.id == 2)
    }

    @Test func aZoomedPaneFillsTheScreen() {
        var list = panes(1, 2)
        list[1].isZoomed = true
        let s = screen(list, root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))
        #expect(s.topLeftPane?.id == 2)
    }

    @Test func viewportColumnsOpenOnTheFirstColumnsTopRow() {
        let first = Column(width: 0.5, root: .pane(1), rows: [Column.Row(height: 400, root: .pane(1)), Column.Row(height: 600, root: .pane(2))])
        let s = screen(panes(3, 2, 1), columns: [first, Column(width: 0.5, root: .pane(3))])
        #expect(s.topLeftPane?.id == 1)
    }

    @Test func aLeftDockIsLeftmostEvenListedLast() {
        let s = screen(panes(1, 2, 3), columns: [Column(width: 0.6, root: .pane(1)), Column(width: 0.4, root: .pane(2)),
                                               Column(width: 0.3, dock: .init(edge: .left), root: .pane(3))])
        #expect(s.topLeftPane?.id == 3)
        // An overlay left dock floats over the strip's left edge: still the leftmost.
        let o = screen(panes(1, 3), columns: [Column(width: 1, root: .pane(1)), Column(width: 0.3, dock: .init(edge: .left, isOverlay: true), root: .pane(3))])
        #expect(o.topLeftPane?.id == 3)
    }

    @Test func aTopBandIsAboveTheStripAndARightDockNeverWins() {
        let s = screen(panes(1, 2, 3), columns: [Column(width: 1, root: .pane(1)),
                                               Column(width: 0.3, dock: .init(edge: .top), root: .pane(2)),
                                               Column(width: 0.3, dock: .init(edge: .right), root: .pane(3))])
        #expect(s.topLeftPane?.id == 2)
        let r = screen(panes(3, 1), columns: [Column(width: 0.3, dock: .init(edge: .right), root: .pane(3)), Column(width: 1, root: .pane(1))])
        #expect(r.topLeftPane?.id == 1)
    }

    @Test func noTreeFallsBackToTheFirstPaneListed() {
        #expect(screen(panes(5, 6)).topLeftPane?.id == 5)
        #expect(screen([]).topLeftPane == nil)
    }

    @Test func theTabIsThePanesActiveTabOnTheShownScreen() {
        let shown = Layout.Screen(id: 2, isActive: true, panes: [Pane(id: 7, tabIDs: ["a", "b"], activeTabID: "b"), Pane(id: 8, tabIDs: ["c"])],
                                  root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(7), second: .pane(8)))
        let hidden = Layout.Screen(id: 1, isActive: false, panes: [Pane(id: 1, tabIDs: ["z"], activeTabID: "z")], root: .pane(1))
        #expect(Layout(screens: [hidden, shown]).topLeftTabID == "b")
        // The pane's active tab not listed on the phone: its first listed tab.
        let unlisted = Layout.Screen(id: 1, isActive: true, panes: [Pane(id: 1, tabIDs: ["x", "y"], activeTabID: "gone")], root: .pane(1))
        #expect(Layout(screens: [unlisted]).topLeftTabID == "x")
        let empty = Layout.Screen(id: 1, isActive: true, panes: [Pane(id: 1, tabIDs: [], tabCount: 2)], root: .pane(1))
        #expect(Layout(screens: [empty]).topLeftTabID == nil)
    }

    @MainActor @Test func theStoreOpensOnTheTopLeftTabOverTheMacsActiveTab() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        var ws = try #require(store.workspace(id: "ws-cmux"))
        ws.activeTabID = "t-docs"
        ws.layout = Layout(screens: [screen([Pane(id: 2, tabIDs: ["t-docs"], activeTabID: "t-docs", isFocused: true),
                                             Pane(id: 1, tabIDs: ["t-claude", "t-zsh"], activeTabID: "t-zsh")],
                                            root: .split(id: 9, axis: .vertical, ratio: 0.5, first: .pane(1), second: .pane(2)))])
        store.workspaces = store.workspaces.map { $0.id == ws.id ? ws : $0 }
        let shown = try #require(store.workspace(id: "ws-cmux"))
        #expect(store.openingTab(for: shown)?.id == "t-zsh")
        store.noteOpened(tabID: "t-docs", in: ws.id)
        #expect(store.openingTab(for: shown)?.id == "t-zsh")
        store.requestOpen(tabID: "t-claude", in: ws.id)
        #expect(store.openingTab(for: shown)?.id == "t-claude")
    }
}
