import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite struct EncodingTests {
    private func object<R: DaemonRequest>(_ request: R, id: UInt64? = 7) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: id)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func envelopeCarriesIDAndCommand() throws {
        let json = try object(SubscribeRequest())
        #expect(json["id"] == .number(7))
        #expect(json["cmd"] == .string("subscribe"))
        #expect(json["tree_events"] == .string("deltas"))
    }

    @Test func durableMutationFieldsAreSnakeCase() throws {
        let mutation = MutationIdentity(origin: "cmux-next", mutationID: "m1",
                                        expectedGeneration: "gen", expectedRevision: 4)
        let json = try object(RenameWorkspaceRequest(workspace: .key("k1"), name: "api", mutation: mutation))
        #expect(json["cmd"] == .string("rename-workspace"))
        #expect(json["key"] == .string("k1"))
        #expect(json["workspace"] == nil)
        #expect(json["name"] == .string("api"))
        #expect(json["origin"] == .string("cmux-next"))
        #expect(json["mutation_id"] == .string("m1"))
        #expect(json["expected_generation"] == .string("gen"))
        #expect(json["expected_revision"] == .number(4))
    }

    @Test func createTerminalFlattensSizeAndIdentity() throws {
        let json = try object(CreateTerminalRequest(
            workspace: .handle(3), argv: ["zsh", "-l"], cwd: "/tmp", size: CellSize(cols: 80, rows: 24),
            terminalID: "abc", mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(json["workspace"] == .number(3))
        #expect(json["cols"] == .number(80))
        #expect(json["rows"] == .number(24))
        #expect(json["terminal_id"] == .string("abc"))
        #expect(json["argv"] == .array([.string("zsh"), .string("-l")]))
        #expect(json["size"] == nil)
    }

    @Test func closeTabsAndEndTerminalsEncodeOnlyWhenSet() throws {
        let tabs = try object(CloseTabsRequest(surfaces: [3, 5], endTerminals: true, transaction: "t1",
                                               mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(tabs["cmd"] == .string("close-tabs"))
        #expect(tabs["surfaces"] == .array([.number(3), .number(5)]))
        #expect(tabs["end_terminals"] == .bool(true))
        #expect(tabs["transaction"] == .string("t1"))
        #expect(tabs["mutation_id"] == .string("m"))
        let plain = try object(CloseTabsRequest(surfaces: [3], endTerminals: false, mutation: nil))
        #expect(plain["end_terminals"] == nil)

        let workspace = try object(CloseWorkspaceRequest(workspace: .key("k1"), endTerminals: true, mutation: nil))
        #expect(workspace["key"] == .string("k1"))
        #expect(workspace["end_terminals"] == .bool(true))
        #expect(try object(CloseWorkspaceRequest(workspace: .key("k1"), mutation: nil))["end_terminals"] == nil)
        #expect(try object(ClosePaneRequest(pane: 4, endTerminals: true))["end_terminals"] == .bool(true))
        #expect(try object(ClosePaneRequest(pane: 4))["end_terminals"] == nil)
        #expect(try object(CloseScreenRequest(screen: 2, endTerminals: true))["screen"] == .number(2))
        #expect(try object(CloseTabGroupRequest(group: "g", endTerminals: true))["end_terminals"] == .bool(true))
    }

    @Test func closeTabsResultDecodes() throws {
        let line = Data(#"{"id":1,"ok":true,"data":{"closed":[3,5],"terminals":[{"terminal_id":"ab","terminal_incarnation":null}],"resource_revision":9,"replayed":false,"transaction":"t1"}}"#.utf8)
        let result = try WireCoding.decodeResponse(CloseTabsResult.self, from: line)
        #expect(result.closed == [3, 5])
        #expect(result.terminals.map(\.terminalID) == ["ab"])
        #expect(result.terminals.first?.terminalIncarnation == nil)
        #expect(result.resourceRevision == 9)
    }

    @Test func sendInputUsesBase64() throws {
        let json = try object(SendInputRequest(surface: 3, bytes: Data("echo hi\r".utf8)))
        #expect(json["bytes"] == .string(Data("echo hi\r".utf8).base64EncodedString()))
        #expect(json["surface"] == .number(3))
        #expect(json["text"] == nil)
    }

    @Test func attachByIdentityOmitsSurface() throws {
        let json = try object(AttachSurfaceRequest(surface: nil, expectedGeneration: "g", expectedTerminalID: "t",
                                                   size: CellSize(cols: 10, rows: 5)))
        #expect(json["surface"] == nil)
        #expect(json["expected_generation"] == .string("g"))
        #expect(json["expected_terminal_id"] == .string("t"))
        #expect(json["mode"] == .string("bytes"))
        #expect(json["cols"] == .number(10))
    }

    @Test func layoutAndProjectionCommands() throws {
        let split = try object(SplitRequest(pane: 4, direction: .down, tab: 9))
        #expect(split["dir"] == .string("down"))
        // The daemon has no split `tab`; the connection routes it to move-tab-to-split.
        #expect(split["tab"] == nil)
        let width = try object(SetColumnWidthRequest(pane: 7, width: 0.5, transaction: 11))
        #expect(width["cmd"] == .string("set-viewport-pane-width"))
        #expect(width["transaction"] == .number(11))
        let swap = try object(SwapPaneRequest(pane: 1, target: .direction(.left)))
        #expect(swap["dir"] == .string("left"))
        let put = try object(PutFrontendProjectionRequest(
            frontend: "cmux-next", scope: .personal, subjectKey: "w1", schemaVersion: 2,
            projection: .object(["a": .bool(true)]), mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(put["subject_key"] == .string("w1"))
        #expect(put["schema_version"] == .number(2))
        #expect(put["projection"]?["a"] == .bool(true))
        #expect(put["mutation_id"] == .string("m"))
        let undo = try object(UndoLayoutRequest(pane: 1, revision: 3, confirmClose: true))
        #expect(undo["confirm_close"] == .bool(true))
    }

    /// DOCK-WIRE (R87): `set-column-dock {pane, dock, edge?, mode?}`; no `sticky`.
    @Test func setColumnDockEncodesDock() throws {
        let pin = try object(SetColumnDockRequest(pane: 4, dock: DockSnapshot(edge: .left, mode: .overlay), transaction: 9))
        #expect(pin["cmd"] == .string("set-column-dock"))
        #expect(pin["dock"] == .bool(true))
        #expect(pin["edge"] == .string("left"))
        #expect(pin["mode"] == .string("overlay"))
        #expect(pin["sticky"] == nil)
        let unpin = try object(SetColumnDockRequest(pane: 4, dock: nil))
        #expect(unpin["dock"] == .bool(false))
        #expect(unpin["sticky"] == nil)
    }

    /// `dock-column-role-v1`: an agent chat dock read from the daemon is sent
    /// back with its role; a dock without one sends none.
    @Test func dockRequestsCarryTheDockRole() throws {
        let chat = try JSONDecoder().decode(DockSnapshot.self, from: Data(#"{"edge":"left","mode":"docked","role":"agent_chat"}"#.utf8))
        #expect(try object(SetColumnDockRequest(pane: 4, dock: chat))["role"] == .string("agent_chat"))
        let move = try object(MoveTabToColumnRequest(surface: 3, target: .pane(7), dock: chat))
        #expect(move["dock"]?["role"] == .string("agent_chat"))
        let plain = DockSnapshot(edge: .left, mode: .docked)
        #expect(try object(SetColumnDockRequest(pane: 4, dock: plain))["role"] == nil)
        #expect(try object(MoveTabToColumnRequest(surface: 3, target: .pane(7), dock: plain))["dock"]?["role"] == nil)
    }

    @Test func tabDragCommandsCarryTransaction() throws {
        let split = try object(MoveTabToSplitRequest(surface: 3, pane: 4, edge: .left, transaction: "tx"))
        #expect(split["cmd"] == .string("move-tab-to-split"))
        #expect(split["edge"] == .string("left"))
        #expect(split["transaction"] == .string("tx"))
        let column = try object(MoveTabToColumnRequest(surface: 3, target: .screen(5), afterColumn: 9, width: 0.5, transaction: "tx"))
        #expect(column["cmd"] == .string("move-tab-to-column"))
        #expect(column["after_column"] == .number(9))
        #expect(column["screen"] == .number(5))
        #expect(column["pane"] == nil)
        let byPane = try object(MoveTabToColumnRequest(surface: 3, target: .pane(7)))
        #expect(byPane["pane"] == .number(7))
        #expect(byPane["dock"] == nil)
        // A docked new column (dock-columns-v1) carries the dock as {edge, mode}.
        let docked = try object(MoveTabToColumnRequest(surface: 3, target: .pane(7), width: 0.3,
                                                       dock: DockSnapshot(edge: .bottom, mode: .overlay)))
        #expect(docked["dock"]?["edge"] == .string("bottom"))
        #expect(docked["dock"]?["mode"] == .string("overlay"))
        // Docking a pane's only tab leaves a fresh terminal (tab-column-respawn-v1).
        let respawned = try object(MoveTabToColumnRespawnRequest(
            MoveTabToColumnRequest(surface: 3, target: .pane(7), width: 0.4, dock: DockSnapshot(edge: .right, mode: .docked)),
            respawn: .terminal(SpawnOptions(cwd: "/tmp"))))
        #expect(respawned["cmd"] == .string("move-tab-to-column"))
        #expect(respawned["dock"]?["edge"] == .string("right"))
        #expect(respawned["respawn"]?["kind"] == .string("terminal"))
        #expect(respawned["respawn"]?["cwd"] == .string("/tmp"))
        let workspace = try object(MoveTabToNewWorkspaceRequest(surface: 3, group: "g", index: 2))
        #expect(workspace["cmd"] == .string("move-tab-to-new-workspace"))
        #expect(workspace["group"] == .string("g"))
        #expect(workspace["transaction"] == nil)
        // `name` only when given (`tab-workspace-name-v1`; older daemons refuse unknown fields).
        #expect(workspace["name"] == nil)
        #expect(try object(MoveTabToNewWorkspaceRequest(surface: 3, name: "vim"))["name"] == .string("vim"))
        // A browser respawn names the page, engine and profile; never the dragged tab's URL.
        let respawn = try object(MoveTabToSplitRespawnRequest(
            surface: 3, pane: 4, edge: .right, respawn: .browser(url: "chrome://newtab/", engine: .cef, profileID: "work")))
        #expect(respawn["cmd"] == .string("move-tab-to-split"))
        #expect(respawn["respawn"]?["kind"] == .string("browser"))
        #expect(respawn["respawn"]?["url"] == .string("chrome://newtab/"))
        #expect(respawn["respawn"]?["engine"] == .string("cef"))
        #expect(respawn["respawn"]?["profile_id"] == .string("work"))
        let move = try object(MoveTabRequest(surface: 3, pane: 7, index: 0, transaction: "tx"))
        #expect(move["transaction"] == .string("tx"))
        let toWorkspace = try object(MoveTabToWorkspaceRequest(surface: 3, workspace: nil))
        #expect(toWorkspace["workspace"] == nil)
    }

    @Test func tabGroupAndSavedGroupCommands() throws {
        let create = try object(CreateTabGroupRequest(tabs: [3, 6], name: "API", color: "green", transaction: "t1"))
        #expect(create["cmd"] == .string("create-tab-group"))
        #expect(create["surfaces"] == .array([.number(3), .number(6)]))
        #expect(create["pane"] == nil)
        #expect(create["transaction"] == .string("t1"))
        let update = try object(UpdateTabGroupRequest(group: "tg1", color: .set("red"), collapsed: true))
        #expect(update["color"] == .string("red"))
        #expect(update["collapsed"] == .bool(true))
        #expect(update["transaction"] == nil)
        let add = try object(AddTabsToGroupRequest(group: "tg1", tabs: [7], transaction: "t3"))
        #expect(add["cmd"] == .string("add-tabs-to-tab-group"))
        #expect(add["surfaces"] == .array([.number(7)]))
        let remove = try object(RemoveTabsFromGroupRequest(tabs: [7]))
        #expect(remove["surfaces"] == .array([.number(7)]))
        let toColumn = try object(MoveTabGroupToColumnRequest(group: "tg1", target: .pane(4), transaction: "t2"))
        #expect(toColumn["cmd"] == .string("move-tab-group-to-column"))
        #expect(toColumn["pane"] == .number(4))
        let toWorkspace = try object(MoveTabGroupToNewWorkspaceRequest(group: "tg1", workspaceGroup: "agents"))
        #expect(toWorkspace["workspace_group"] == .string("agents"))
        #expect(try object(UngroupTabGroupRequest(group: "tg1"))["cmd"] == .string("ungroup-tab-group"))
        #expect(try object(CloseTabGroupRequest(group: "tg1"))["cmd"] == .string("close-tab-group"))
        let reopen = try object(ReopenSavedTabGroupRequest(saved: "s1", pane: 4))
        #expect(reopen["cmd"] == .string("reopen-saved-tab-group"))
        #expect(reopen["saved"] == .string("s1"))
        #expect(reopen["pane"] == .number(4))
        #expect(try object(SaveTabGroupRequest(group: "tg1"))["group"] == .string("tg1"))
        #expect(try object(UnsaveTabGroupRequest(group: "tg1"))["group"] == .string("tg1"))
        #expect(try object(DeleteSavedTabGroupRequest(saved: "s1"))["cmd"] == .string("delete-saved-tab-group"))
        #expect(try object(ListSavedTabGroupsRequest())["cmd"] == .string("list-saved-tab-groups"))
        #expect(try object(AckTabNotificationsRequest(surface: 3))["cmd"] == .string("ack-tab-notifications"))
    }

    @Test func windowStateDocumentRoundTripsThroughJSONValue() throws {
        var document = WindowStateDocument()
        document.upsert(WindowRecord(id: "w1", workspaceKey: "k1", frame: WindowFrame(x: 10, y: 20, width: 800, height: 600)))
        document.upsert(WindowRecord(id: "w2", workspaceKey: "gone"))
        document.upsert(WindowRecord(id: "w1", workspaceKey: "k2"))
        document.prune(liveWorkspaces: ["k2"])
        let restored = try WindowStateDocument(jsonValue: document.jsonValue())
        #expect(restored == document)
        #expect(restored.windows.map(\.id) == ["w1"])
        #expect(restored.windows[0].workspaceKey == "k2")
        #expect(try document.jsonValue()["windows"] != nil)
    }

    @Test func windowRecordCarriesWindowMembership() throws {
        var document = WindowStateDocument()
        document.upsert(WindowRecord(id: "w1", workspaceKey: "k2", workspaceKeys: ["k1", "k2", "gone"], display: "D"))
        document.prune(liveWorkspaces: ["k1", "k2"])
        let value = try document.jsonValue()
        let restored = try WindowStateDocument(jsonValue: value)
        #expect(restored == document)
        #expect(restored.windows[0].workspaceKeys == ["k1", "k2"])
        #expect(restored.windows[0].display == "D")
        // Records from older builds have no membership list.
        let legacy = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"old","workspace_key":"k1"}"#.utf8))
        #expect(legacy.workspaceKeys.isEmpty)
        #expect(legacy.workspaceKey == "k1")
        // A window whose every workspace is gone is dropped.
        document.prune(liveWorkspaces: [])
        #expect(document.windows.isEmpty)
    }

    @Test func pruneDropsEveryWindowWithoutWorkspaces() {
        // A window exists only while it holds a workspace, so a record that
        // never listed one (an old empty state, another client) is dropped too.
        var document = WindowStateDocument(windows: [WindowRecord(id: "empty"), WindowRecord(id: "w1", workspaceKey: "k1")])
        document.prune(liveWorkspaces: ["k1"])
        #expect(document.windows.map(\.id) == ["w1"])
    }

    @Test func sidebarHiddenRoundTripsAndLegacyCollapsedMigratesToHidden() throws {
        let record = WindowRecord(id: "w1", sidebarWidth: 230, sidebarHidden: true)
        let data = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sidebar_hidden"] as? Bool == true)
        #expect(object["sidebar_collapsed"] == nil)
        #expect(try JSONDecoder().decode(WindowRecord.self, from: data) == record)
        // Older builds saved icons-only (or hidden) as `sidebar_collapsed`.
        let iconsOnly = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"old","sidebar_collapsed":true,"sidebar_width":250}"#.utf8))
        #expect(iconsOnly.sidebarHidden)
        #expect(iconsOnly.sidebarWidth == 250)
        let expanded = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"old","sidebar_collapsed":false}"#.utf8))
        #expect(!expanded.sidebarHidden)
        let none = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"old"}"#.utf8))
        #expect(!none.sidebarHidden)
        // The new key wins over a stale legacy one.
        let both = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"x","sidebar_collapsed":true,"sidebar_hidden":false}"#.utf8))
        #expect(!both.sidebarHidden)
    }

    @Test func groupAndMetadataCommandsUseNullToClear() throws {
        let metadata = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), color: .clear, icon: .set("folder"),
                                                              mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(metadata["cmd"] == .string("set-workspace-metadata"))
        #expect(metadata["color"] == .null)
        #expect(metadata["icon"] == .string("folder"))
        #expect(metadata.keys.contains("title") == false)
        #expect(metadata["mutation_id"] == .string("m"))

        let browser = try object(NewFrontendBrowserTabRequest(url: "https://x", engine: .webkit, pane: 3, profileID: "p1"))
        #expect(browser["cmd"] == .string("new-frontend-browser-tab"))
        #expect(browser["engine"] == .string("webkit"))
        #expect(browser["profile_id"] == .string("p1"))
        let navigate = try object(UpdateFrontendBrowserTabRequest(surface: 5, title: "Docs", faviconURL: .clear))
        #expect(navigate["favicon_url"] == .null)
        #expect(navigate["url"] == nil)
        let pin = try object(SetTabPinnedRequest(surface: 4, pinned: true))
        #expect(pin["pinned"] == .bool(true))
    }

    @Test func terminalEnvReachesSpawnCommands() throws {
        let env = ["PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "en_US.UTF-8"]
        let tab = try object(NewTabRequest(pane: 3, options: SpawnOptions(cwd: "/tmp", env: env)))
        #expect(tab["env"] == .object(["PATH": .string("/opt/homebrew/bin:/usr/bin"), "LANG": .string("en_US.UTF-8")]))
        #expect(tab["cwd"] == .string("/tmp"))
        let split = try object(SplitRequest(pane: 3, direction: .right, options: SpawnOptions(cwd: "/tmp", env: env)))
        #expect(split["cwd"] == .string("/tmp"))
        #expect(split["env"]?["PATH"] == .string("/opt/homebrew/bin:/usr/bin"))
        #expect(split["tab"] == nil)
        let terminal = try object(CreateTerminalRequest(workspace: .key("k1"), env: env, mutation: nil))
        #expect(terminal["env"]?["LANG"] == .string("en_US.UTF-8"))
        #expect(try object(NewTabRequest(pane: 3))["env"] == nil)
    }
}
