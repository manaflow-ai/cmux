import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// The Feed drops rows whose tab was closed (on the Mac or the phone, alone or with its
/// workspace, before or after launch): those events are no longer news to the person.
@MainActor
@Suite struct FeedClosedTabsTests {
    static let mac = "mac-1"

    static func row(_ id: String, workspace: String = "w1", tab: String, kind: FeedItem.Kind = .response,
                    terminal: Bool = false, mac: String? = FeedClosedTabsTests.mac, age: TimeInterval = 0) -> FeedItem {
        var item = FeedItem(id: id, kind: kind, workspaceID: workspace, tabID: tab, agentName: "Claude", harness: "claude",
                            workspaceTitle: workspace, markdown: id, quote: nil, createdAt: Date(timeIntervalSince1970: 1_000 - age))
        item.macID = mac
        item.opensTerminal = terminal
        return item
    }

    static func workspace(_ id: String, tabs: [String]) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~",
                  tabs: tabs.map { WorkspaceTab(id: $0, kind: .terminal, title: $0) }, lastActivityAt: Date())
    }

    static func open(_ workspaces: [Workspace], complete: Bool = true) -> FeedOpenTabs {
        FeedOpenTabs(workspaces: workspaces, complete: complete)
    }

    @Test func everyRowShowsUntilTheMacIsHeardFrom() {
        let store = FeedStore(items: [Self.row("a", tab: "t1"), Self.row("b", workspace: "w2", tab: "t9")])
        #expect(store.visibleItems.map(\.id) == ["a", "b"])
    }

    @Test func aTabClosedOnTheMacHidesItsRows() {
        let store = FeedStore(items: [Self.row("a", tab: "t1"), Self.row("b", tab: "t2", age: 1)])
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: ["t1", "t2"])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a", "b"])
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: ["t1"])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a"])
        // Kept in the store: a tab a partial tree left out comes back with the next tree.
        #expect(store.item(id: "b") != nil)
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: ["t1", "t2"])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a", "b"])
    }

    @Test func aClosedWorkspaceHidesEveryRowOfIt() {
        let store = FeedStore(items: [Self.row("a", tab: "t1"), Self.row("b", workspace: "w2", tab: "t3", age: 1)])
        store.setOpenTabs(Self.open([Self.workspace("w2", tabs: ["t3"])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["b"])
        store.setOpenTabs(Self.open([]), macID: Self.mac)
        #expect(store.visibleItems.isEmpty)
        #expect(store.count(.all) == 0)
    }

    @Test func theLaunchSnapshotHidesOnlyTabsGoneFromWorkspacesItLists() {
        // The snapshot may hold only the first screen of rows and never the home workspace.
        let store = FeedStore(items: [Self.row("a", tab: "t1"), Self.row("b", tab: "t2", age: 1),
                                      Self.row("home", workspace: "home", tab: "h1", age: 2)])
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: ["t1"])], complete: false), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a", "home"])
        // The Mac's tree is complete: a workspace it doesn't list was closed.
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: ["t1"])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a"])
    }

    @Test func anotherMacsTabsJudgeOnlyItsOwnRows() {
        let store = FeedStore(items: [Self.row("a", tab: "t1"), Self.row("other", tab: "t1", mac: "mac-2", age: 1)])
        store.setOpenTabs(Self.open([]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["other"])
    }

    @Test func rowsWithNoTabStay() {
        let unbound = Self.row("chat", workspace: "", tab: "session-7")
        let request = Self.row("macreq", workspace: "", tab: "", kind: .needsInput)
        let store = FeedStore(items: [unbound, request])
        store.setOpenTabs(Self.open([]), macID: Self.mac)
        #expect(Set(store.visibleItems.map(\.id)) == ["chat", "macreq"])
    }

    @Test func aChatAskStillWaitingOutlivesItsTabButATerminalAskDoesNot() {
        let chatAsk = Self.row("chat-ask", tab: "t1", kind: .needsInput)
        let terminalAsk = Self.row("term-ask", tab: "t2", kind: .needsInput, terminal: true, age: 1)
        let store = FeedStore(items: [chatAsk, terminalAsk])
        #expect(store.needsYouCount == 2)
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: [])]), macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["chat-ask"])
        #expect(store.needsYouCount == 1)
        // Answered: an ordinary row of a closed tab, so it goes.
        store.resolveElsewhere("chat-ask", text: "Answered")
        #expect(store.visibleItems.isEmpty)
        #expect(store.needsYouCount == 0)
    }

    @Test func aReReadThatNoLongerPlacesAChatKeepsItsClosedTab() {
        // A chat's turn row is read again after its tab closed: its session is placed nowhere.
        let store = FeedStore(items: [Self.row("turn", tab: "t1")])
        store.setOpenTabs(Self.open([Self.workspace("w1", tabs: [])]), macID: Self.mac)
        #expect(store.visibleItems.isEmpty)
        store.mergeHistory([Self.row("turn", workspace: "", tab: "session-1")])
        #expect(store.item(id: "turn")?.tabID == "t1")
        #expect(store.visibleItems.isEmpty)
        store.upsert(Self.row("turn", workspace: "", tab: "session-1"), atTop: true)
        #expect(store.item(id: "turn")?.tabID == "t1")
        #expect(store.visibleItems.isEmpty)
    }

    @Test func aForgottenMacHidesNothing() {
        let store = FeedStore(items: [Self.row("a", tab: "t1")])
        store.setOpenTabs(Self.open([]), macID: Self.mac)
        #expect(store.visibleItems.isEmpty)
        store.forgetOpenTabs(macID: Self.mac)
        #expect(store.visibleItems.map(\.id) == ["a"])
    }

    @Test func aTreeListsHomeWorkspaceTabsAsOpen() throws {
        let reply = #"{"ok":true,"data":{"workspaces":[]}}"#
        var tree = try DaemonTree(reply: Data(reply.utf8), macID: Self.mac)
        tree.workspaces = [Self.workspace("w1", tabs: ["t1"])]
        tree.homeWorkspaces = [Self.workspace("home", tabs: ["h1"])]
        let open = FeedOpenTabs(tree: tree)
        #expect(open.complete)
        #expect(open.tabsByWorkspace == ["w1": ["t1"], "home": ["h1"]])
    }
}
