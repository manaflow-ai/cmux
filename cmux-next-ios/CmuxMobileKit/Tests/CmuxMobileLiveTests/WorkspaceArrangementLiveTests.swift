import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Parity round 2 on the live side: what the daemon tree says about pins,
/// colors and order, and the words a phone shows.
@Suite struct WorkspaceArrangementLiveTests {
    static let reply = Data(#"""
    {"ok":true,"data":{"registry_id":"reg_1","workspace_revision":4,"workspaces":[
      {"key":"k-a","title":"alpha","resource_id":"ws_a","color":"blue","pinned":false,"screens":[]},
      {"key":"k-b","title":"beta","resource_id":"ws_b","color":"#ff8800cc","pinned":true,"screens":[]},
      {"key":"k-c","title":"gamma","resource_id":"ws_c","color":"chartreuse","screens":[]}
    ]}}
    """#.utf8)

    @Test func treeCarriesPinsColorsAndIds() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "m")
        #expect(tree.registryID == "reg_1")
        #expect(tree.legacyPinned == ["k-b"])
        #expect(tree.workspaces.map(\.resourceID) == ["ws_a", "ws_b", "ws_c"])
        // A palette name, a hex color (alpha dropped), and an unknown name (none).
        #expect(tree.workspaces.map(\.colorHex) == ["blue", "#ff8800", nil])
        #expect(tree.workspaces.map(\.isPinned) == [false, true, false])
    }

    @Test func arrangementOrdersAndPinsTheTree() throws {
        var tree = try DaemonTree(reply: Self.reply, macID: "m")
        tree.apply(SidebarArrangement(rows: [.init(session: "reg_1", key: "k-c", index: 0), .init(session: "reg_1", key: "k-a", index: 1)],
                                      pins: [.init(itemID: "itm_aaaaaaaaaaaaaaaa", value: "reg_1:ws_a")]))
        #expect(tree.workspaces.map(\.sidebarIndex) == [1, 2 + 1, 0])
        #expect(tree.workspaces.map(\.isPinned) == [true, true, false])
        #expect(tree.workspaces[0].pinItemID == "itm_aaaaaaaaaaaaaaaa")
        // No arrangement (an older Mac): the daemon's order.
        var plain = try DaemonTree(reply: Self.reply, macID: "m")
        plain.apply(nil)
        #expect(plain.workspaces.map(\.sidebarIndex) == [0, 1, 2])
    }

    @Test func personalChangesRelistTheTree() {
        #expect(DaemonEvent.parse(Data(#"{"event":"personal-changed"}"#.utf8)) == .treeChanged)
    }

    /// Mark Workspace as Read acknowledges the tabs the Mac shows unread, else all of them.
    @Test func readMarksAcknowledgeUnreadTabs() throws {
        let line = Data(#"""
        {"ok":true,"data":{"workspaces":[{"key":"k","title":"w","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
          {"surface":5,"kind":"pty","notification":{"notification":9,"unread":true}},
          {"surface":6,"kind":"pty"}]}]}]}]}}
        """#.utf8)
        let tree = try DaemonTree(reply: line, macID: "m")
        var ws = try #require(tree.workspaces.first)
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: tree) == [5])
        let quiet = try DaemonTree(reply: Data(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\"unread\":true", with: "\"unread\":false").utf8), macID: "m")
        ws.hasUnread = true
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: quiet) == [5, 6])
        ws.hasUnread = false
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: quiet).isEmpty)
    }

    /// The trust question stays on the Mac: the phone says what to do, step by step.
    @Test func trustStepsSayWhatToDo() {
        let text = LiveWorkspaceCreationBackend.trustSteps(folder: "proj")
        #expect(text.hasPrefix("Claude hasn't been trusted in proj yet."))
        #expect(text.contains("1. On the Mac, open this workspace in cmux and choose Trust when it asks."))
        #expect(text.contains("2. Here, open this workspace's terminal, type claude, press Return"))
        #expect(text.hasSuffix("Then start the chat again."))
        // Another agent's chat names that agent, and has no claude step.
        let codex = LiveWorkspaceCreationBackend.trustSteps(folder: "proj", agent: "Codex", family: "codex")
        #expect(codex == "Codex hasn't been trusted in proj yet. On the Mac, open this workspace in cmux and choose Trust when it asks, then start the chat again.")
    }

    /// The cmux model service down on the Mac (`route.unavailable`): a plain sentence, never
    /// the Mac's command line (round 3 live: the phone said only "Couldn't open an agent chat").
    @Test func aModelServiceThatIsDownSaysSo() {
        let down = LiveWorkspaceCreationBackend.routeUnavailable(
            "the local CodeRouter is not running (Resource temporarily unavailable (os error 35)); start it with `acpmux router serve`")
        #expect(down == "cmux's model service isn't running on the Mac. Quit and reopen cmux on the Mac, then try again, or choose another agent.")
        let signedOut = LiveWorkspaceCreationBackend.routeUnavailable(
            "the cmux model router is not connected (open cmux to sign the local router in)")
        #expect(signedOut.hasPrefix("cmux's model service isn't signed in on the Mac."))
        #expect(!down.contains("acpmux") && !signedOut.contains("router"))
    }

    /// Open Folder… types `cd` with the same rules as Recent Directories.
    @Test func openFolderSharesTheTypedCdRules() {
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~/code/app") == "cd ~/'code/app' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/tmp/bang!") == nil)
        #expect(!WorkspaceFolderPath.isTypable("/tmp/bang!"))
    }
}

/// Parity round 2, batch 2: icon, Clear Workspace Name, New Agent Chat in a folder,
/// the agent chat queue (Edit queued prompt, Send now, Move up / down).
@Suite struct WorkspaceBatchTwoLiveTests {
    @Test func customTitleIsTheDisplayNameOverTheName() throws {
        let reply = Data(#"""
        {"ok":true,"data":{"workspaces":[
          {"key":"a","name":"proj","title":"Release","icon":"hammer","screens":[]},
          {"key":"b","name":"proj","title":"","screens":[]},
          {"key":"c","name":"proj","screens":[]}
        ]}}
        """#.utf8)
        let tree = try DaemonTree(reply: reply, macID: "m")
        #expect(tree.workspaces.map(\.hasCustomTitle) == [true, false, false])
        #expect(tree.workspaces.map(\.title) == ["Release", "proj", "proj"])
        #expect(tree.workspaces[0].icon == "hammer")
    }

    /// A chat workspace starts only in one of the Mac's workspace folders (acpmux's
    /// remote guard takes those), given as the phone shows it or absolute.
    @Test func chatFolderIsAMacWorkspaceFolder() {
        let known: Set<String> = ["/Users/me/code/app", "/Users/me/notes"]
        #expect(LiveWorkspaceCreationBackend.chatFolder("~/code/app", known: known) == "/Users/me/code/app")
        #expect(LiveWorkspaceCreationBackend.chatFolder("/Users/me/notes", known: known) == "/Users/me/notes")
        #expect(LiveWorkspaceCreationBackend.chatFolder("~/elsewhere", known: known) == nil)
        #expect(LiveWorkspaceCreationBackend.chatFolder(nil, known: known) == nil)
        #expect(LiveWorkspaceCreationBackend.chatFolderRefusal.contains("Open Folder…"))
    }

    @Test func queueRecordsMapToTheChat() throws {
        let records = AcpmuxRecords(sessionID: "s1")
        func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }
        #expect(records.map(json(#"{"seq":1,"dir":"mux","kind":"queue_updated","msg":{"promptId":"p1","text":"new text"}}"#))
                == [.queueUpdated(promptId: "p1", text: "new text")])
        #expect(records.map(json(#"{"seq":2,"dir":"mux","kind":"queue_order","msg":{"promptId":"p2","order":["p2","p1"]}}"#))
                == [.queueOrder(["p2", "p1"])])
    }
}

/// Parity round 3: the lines the phone sends for the Mac's workspace groups.
@Suite struct WorkspaceGroupLiveTests {
    @Test func placeNamesTheWorkspacesResource() throws {
        var ws = Workspace(id: "k", macID: "m", title: "w", directory: "~", tabs: [], lastActivityAt: Date())
        #expect(throws: WorkspaceCreationError.self) { try LiveWorkspaceCreationBackend.placeParams(ws, group: "grp_1") }
        ws.resourceID = "ws_1"
        let into = try LiveWorkspaceCreationBackend.placeParams(ws, group: "grp_1")
        #expect(into["workspace"] as? String == "ws_1" && into["group"] as? String == "grp_1")
        let out = try LiveWorkspaceCreationBackend.placeParams(ws, group: nil)
        #expect(out["group"] is NSNull)
    }

    @Test func createdGroupIDFromTheResponse() {
        #expect(LiveWorkspaceCreationBackend.createdGroupID(["ok": true, "result": ["value": ["id": "grp_9", "name": "x"]]]) == "grp_9")
        #expect(LiveWorkspaceCreationBackend.createdGroupID(["ok": true, "result": ["id": "grp_8"]]) == "grp_8")
        #expect(LiveWorkspaceCreationBackend.createdGroupID(["ok": true]) == nil)
    }

    /// The tree takes the Mac's groups from `list-personal`.
    @Test func treeCarriesGroups() throws {
        var tree = try DaemonTree(reply: WorkspaceArrangementLiveTests.reply, macID: "m")
        let group = MacWorkspaceGroup(id: "grp_1", name: "Ship", color: "red")
        tree.apply(SidebarArrangement(rows: [.init(session: "reg_1", key: "k-a", index: 0, group: "grp_1"),
                                             .init(session: "reg_1", key: "k-b", index: 1)], groups: [group]))
        #expect(tree.workspaces.map { $0.group?.id } == ["grp_1", nil, nil])
        #expect(tree.workspaces.map(\.sidebarIndex) == [2, 0, 1])
    }
}
