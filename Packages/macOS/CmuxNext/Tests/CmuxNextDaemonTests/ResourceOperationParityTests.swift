import CmuxNextIPC
import Foundation
import Testing
@testable import CmuxNextDaemon

/// StateResourceClient and AgentCLIJobCarrier send generated `cmux.protocol/2`
/// requests (`ResourceOperationClient`) instead of hand-built `ResourceRequestEnvelope`s, and
/// every migrated call writes the same line byte for byte as the envelope it replaces. Each
/// expected envelope below is the params dictionary the call site built before the migration.
struct ResourceOperationParityTests {
    private static let key = "cmux-next-parity-k1"

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func handBuilt(_ operation: String, _ params: [String: JSONValue],
                                  keyed: Bool = true) throws -> String {
        text(try ResourceRequestEnvelope(id: 11, operation: operation, params: params,
                                         idempotencyKey: keyed ? key : nil).line())
    }

    private static func generated<Request: ResourceMutationRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 11, request: request, idempotencyKey: ResourceIdempotencyKey(key)).line())
    }

    private static func generated<Request: ResourceUnkeyedRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 11, request: request).line())
    }

    private static func id(_ raw: String) -> ResourceID { ResourceID(rawValue: raw) }

    @Test func closedReopenAndDelete() throws {
        #expect(try Self.generated(V2ClosedReopenRequest(closed: "closed_1"))
            == Self.handBuilt("closed.reopen", ["closed": .string("closed_1")]))
        #expect(try Self.generated(StateResourceClient.reopenRequest(tab: "tab_1", fallbackPane: "pane_2"))
            == Self.handBuilt("closed.reopen", ["tab": .string("tab_1"), "fallback_pane": .string("pane_2")]))
        #expect(try Self.generated(StateResourceClient.reopenRequest(tab: "tab_1", fallbackPane: nil))
            == Self.handBuilt("closed.reopen", ["tab": .string("tab_1")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(closed: "closed_1"))
            == Self.handBuilt("closed.delete", ["closed": .string("closed_1")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(all: true, sinceMs: String(UInt64(1_700_000_000_123))))
            == Self.handBuilt("closed.delete", ["all": .bool(true), "since_ms": .string("1700000000123")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(all: true))
            == Self.handBuilt("closed.delete", ["all": .bool(true)]))
    }

    @Test func windowRecords() throws {
        #expect(try Self.generated(V2WindowRecordListRequest())
            == Self.handBuilt("window_record.list", [:], keyed: false))
        let record: JSONValue = .object([
            "frame": .array([.number(0), .number(25.5), .number(1440), .number(900)]),
            "title": .string("a/b \"c\""), "fullscreen": .bool(false), "tabs": .null,
        ])
        #expect(try Self.generated(V2WindowRecordPutRequest(installID: "inst_1", record: ResourceJSON(record),
                                                            windowID: "win_1"))
            == Self.handBuilt("window_record.put", ["install_id": .string("inst_1"), "window_id": .string("win_1"),
                                                    "record": record]))
        #expect(try Self.generated(V2WindowRecordDeleteRequest(installID: "inst_1", windowID: "win_1"))
            == Self.handBuilt("window_record.delete", ["install_id": .string("inst_1"), "window_id": .string("win_1")]))
    }

    @Test func workspaceCreate() throws {
        let focused = StateResourceClient.workspaceCreateRequest(name: nil, ephemeral: true, terminal: true, focus: true,
                                                                daemonSupportsFocus: true)
        #expect(try Self.generated(focused) == Self.handBuilt("workspace.create", [
            "initial_content": .string("terminal"), "ephemeral": .bool(true), "focus": .bool(true),
        ]))
        let named = StateResourceClient.workspaceCreateRequest(name: "showcase", ephemeral: false, terminal: false,
                                                              focus: true, daemonSupportsFocus: false)
        #expect(try Self.generated(named) == Self.handBuilt("workspace.create", [
            "initial_content": .string("empty"), "name": .string("showcase"),
        ]))
    }

    /// `.unchanged` leaves a field out and `.clear` sends `null`, as `StateResourceClient.field` did.
    @Test func workspaceUpdateKeepsClearsAndSets() throws {
        let request = StateResourceClient.workspaceUpdateRequest(
            Self.id("ws_1"), title: .set("Build"), color: .clear, icon: .unchanged, description: .set("notes\n\tline"),
            taskStatus: .set(.needsAttention))
        #expect(try Self.generated(request) == Self.handBuilt("workspace.update", [
            "workspace": .string("ws_1"), "title": .string("Build"), "color": .null,
            "description": .string("notes\n\tline"), "task_status": .string("needs-attention"),
        ]))
        let clearStatus = StateResourceClient.workspaceUpdateRequest(
            Self.id("ws_1"), title: .unchanged, color: .unchanged, icon: .clear, description: .unchanged,
            taskStatus: .clear)
        #expect(try Self.generated(clearStatus) == Self.handBuilt("workspace.update", [
            "workspace": .string("ws_1"), "icon": .null, "task_status": .null,
        ]))
    }

    @Test func workspaceAgentFolder() throws {
        let selector = StateResourceClient.selector(Self.id("ws_1"))
        #expect(try Self.generated(V2WorkspaceAgentFolderSetRequest(workspace: selector, path: "/Users/me/src"))
            == Self.handBuilt("workspace.agent_folder.set", ["workspace": .string("ws_1"), "path": .string("/Users/me/src")]))
        #expect(try Self.generated(V2WorkspaceAgentFolderSetRequest(workspace: selector, path: nil))
            == Self.handBuilt("workspace.agent_folder.set", ["workspace": .string("ws_1"), "path": .null]))
    }

    @Test func tabPinAndUpdate() throws {
        let tab = StateResourceClient.selector(Self.id("tab_1"))
        #expect(try Self.generated(V2TabPinRequest(tab: tab)) == Self.handBuilt("tab.pin", ["tab": .string("tab_1")]))
        #expect(try Self.generated(V2TabUnpinRequest(tab: tab)) == Self.handBuilt("tab.unpin", ["tab": .string("tab_1")]))
        let back = (0..<25).map { "https://example.com/\($0)" }
        let forward = (0..<22).map { "https://example.org/\($0)" }
        let request = StateResourceClient.tabRecordUpdateRequest(Self.id("tab_1"), zoom: .set(1.25), icon: .clear,
                                                                 back: back, forward: forward, markedUnread: true)
        #expect(try Self.generated(request) == Self.handBuilt("tab.update", [
            "tab": .string("tab_1"), "marked_unread": .bool(true), "zoom": .number(1.25), "icon": .null,
            "back": .array(back.suffix(20).map { .string($0) }), "forward": .array(forward.prefix(20).map { .string($0) }),
        ]))
        let zoomOnly = StateResourceClient.tabRecordUpdateRequest(Self.id("tab_1"), zoom: .clear, icon: .unchanged,
                                                                  back: nil, forward: nil, markedUnread: nil)
        #expect(try Self.generated(zoomOnly) == Self.handBuilt("tab.update", ["tab": .string("tab_1"), "zoom": .null]))
    }

    @Test func tabGroups() throws {
        let tabs = [Self.id("tab_1"), Self.id("tab_2")]
        let tabIDs: JSONValue = .array([.string("tab_1"), .string("tab_2")])
        #expect(try Self.generated(StateResourceClient.tabGroupCreateRequest(tabs: tabs, name: "Docs", color: "#ff0000"))
            == Self.handBuilt("tab_group.create", ["tabs": tabIDs, "name": .string("Docs"), "color": .string("#ff0000")]))
        #expect(try Self.generated(StateResourceClient.tabGroupCreateRequest(tabs: tabs, name: nil, color: nil))
            == Self.handBuilt("tab_group.create", ["tabs": tabIDs]))
        #expect(try Self.generated(StateResourceClient.tabGroupUpdateRequest("tgrp_1", name: "A", color: "blue", collapsed: true,
                                                                            icon: .clear))
            == Self.handBuilt("tab_group.update", [
                "tab_group": .string("tgrp_1"), "name": .string("A"), "color": .string("blue"), "collapsed": .bool(true),
                "icon": .null,
            ]))
        #expect(try Self.generated(StateResourceClient.tabGroupUpdateRequest("tgrp_1", name: nil, color: nil, collapsed: nil,
                                                                            icon: .set("star")))
            == Self.handBuilt("tab_group.update", ["tab_group": .string("tgrp_1"), "icon": .string("star")]))
        #expect(try Self.generated(StateResourceClient.tabGroupAddTabsRequest(tabs, group: "tgrp_1", index: -3))
            == Self.handBuilt("tab_group.add_tabs", ["tab_group": .string("tgrp_1"), "tabs": tabIDs, "index": .number(0)]))
        #expect(try Self.generated(StateResourceClient.tabGroupAddTabsRequest(tabs, group: "tgrp_1", index: nil))
            == Self.handBuilt("tab_group.add_tabs", ["tab_group": .string("tgrp_1"), "tabs": tabIDs]))
        #expect(try Self.generated(V2TabGroupRemoveTabsRequest(tabs: tabs.map { V2TabID(rawValue: $0.rawValue) }))
            == Self.handBuilt("tab_group.remove_tabs", ["tabs": tabIDs]))
        #expect(try Self.generated(StateResourceClient.tabGroupMoveRequest("tgrp_1", pane: Self.id("pane_9"), index: 4))
            == Self.handBuilt("tab_group.move", ["tab_group": .string("tgrp_1"), "index": .number(4), "pane_id": .string("pane_9")]))
        #expect(try Self.generated(StateResourceClient.tabGroupMoveRequest("tgrp_1", pane: nil, index: 0))
            == Self.handBuilt("tab_group.move", ["tab_group": .string("tgrp_1"), "index": .number(0)]))
        #expect(try Self.generated(V2TabGroupUngroupRequest(tabGroup: "tgrp_1"))
            == Self.handBuilt("tab_group.ungroup", ["tab_group": .string("tgrp_1")]))
        #expect(try Self.generated(V2TabGroupCloseRequest(tabGroup: "tgrp_1"))
            == Self.handBuilt("tab_group.close", ["tab_group": .string("tgrp_1")]))
    }

    @Test func screensAndScreenGroups() throws {
        #expect(try Self.generated(StateResourceClient.screenUpdateRequest(Self.id("screen_1"), pinned: true, color: .set("green"),
                                                                          icon: .clear))
            == Self.handBuilt("screen.update", [
                "screen": .string("screen_1"), "pinned": .bool(true), "color": .string("green"), "icon": .null,
            ]))
        #expect(try Self.generated(StateResourceClient.screenUpdateRequest(Self.id("screen_1"), pinned: nil, color: .clear,
                                                                          icon: .unchanged))
            == Self.handBuilt("screen.update", ["screen": .string("screen_1"), "color": .null]))
        #expect(try Self.generated(V2ScreenMoveRequest(screen: StateResourceClient.selector(Self.id("screen_1")),
                                                       index: StateResourceClient.index(2)))
            == Self.handBuilt("screen.move", ["screen": .string("screen_1"), "index": .number(2)]))
        let screens = [Self.id("screen_1"), Self.id("screen_2")]
        #expect(try Self.generated(StateResourceClient.screenGroupCreateRequest(screens: screens, name: "Pair", color: nil))
            == Self.handBuilt("screen_group.create", [
                "screens": .array([.string("screen_1"), .string("screen_2")]), "name": .string("Pair"),
            ]))
    }

    @Test func personalWorkspaceGroups() throws {
        #expect(try Self.generated(StateResourceClient.workspaceGroupCreateRequest(name: "Work", room: "room_1", color: "red",
                                                                                  index: 3))
            == Self.handBuilt("workspace_group.create", [
                "name": .string("Work"), "room": .string("room_1"), "color": .string("red"), "index": .number(3),
            ]))
        #expect(try Self.generated(StateResourceClient.workspaceGroupCreateRequest(name: "Work", room: nil, color: nil,
                                                                                  index: nil))
            == Self.handBuilt("workspace_group.create", ["name": .string("Work")]))
        let update = StateResourceClient.workspaceGroupUpdateRequest(
            "grp_1", name: "B", color: .clear, collapsed: false, topIndex: .set(-1), icon: .set("folder"), pinned: true)
        #expect(try Self.generated(update) == Self.handBuilt("workspace_group.update", [
            "workspace_group": .string("grp_1"), "name": .string("B"), "color": .null, "collapsed": .bool(false),
            "top_index": .number(0), "icon": .string("folder"), "pinned": .bool(true),
        ]))
        let clearTop = StateResourceClient.workspaceGroupUpdateRequest(
            "grp_1", name: nil, color: .unchanged, collapsed: nil, topIndex: .clear, icon: .unchanged, pinned: nil)
        #expect(try Self.generated(clearTop)
            == Self.handBuilt("workspace_group.update", ["workspace_group": .string("grp_1"), "top_index": .null]))
        #expect(try Self.generated(V2WorkspaceGroupDeleteRequest(workspaceGroup: "grp_1"))
            == Self.handBuilt("workspace_group.delete", ["workspace_group": .string("grp_1")]))
        #expect(try Self.generated(V2WorkspaceGroupMoveRequest(index: StateResourceClient.index(-2), workspaceGroup: "grp_1"))
            == Self.handBuilt("workspace_group.move", ["workspace_group": .string("grp_1"), "index": .number(0)]))
        #expect(try Self.generated(StateResourceClient.workspacePlaceRequest(Self.id("ws_1"), group: .set("grp_1"), index: 5))
            == Self.handBuilt("workspace.place", ["workspace": .string("ws_1"), "group": .string("grp_1"), "index": .number(5)]))
        #expect(try Self.generated(StateResourceClient.workspacePlaceRequest(Self.id("ws_1"), group: .clear, index: nil))
            == Self.handBuilt("workspace.place", ["workspace": .string("ws_1"), "group": .null]))
    }

    @Test func stash() throws {
        #expect(try Self.generated(V2StashListRequest()) == Self.handBuilt("stash.list", [:], keyed: false))
        #expect(try Self.generated(V2StashCreateRequest(tabs: [V2TabID(rawValue: "tab_1")]))
            == Self.handBuilt("stash.create", ["tabs": .array([.string("tab_1")])]))
        #expect(try Self.generated(V2StashCreateRequest(workspace: V2WorkspaceID(rawValue: "ws_1")))
            == Self.handBuilt("stash.create", ["workspace": .string("ws_1")]))
        #expect(try Self.generated(V2StashCreateRequest(name: "Later", workspaces: [V2WorkspaceID(rawValue: "ws_1")]))
            == Self.handBuilt("stash.create", ["workspaces": .array([.string("ws_1")]), "name": .string("Later")]))
        let restore = StateResourceClient.stashRestoreRequest("stash_1", members: ["m_1"], target: .newWorkspace,
                                                              pane: Self.id("pane_1"))
        #expect(try Self.generated(restore) == Self.handBuilt("stash.restore", [
            "stash": .string("stash_1"), "target": .string("new_workspace"), "members": .array([.string("m_1")]),
            "pane": .string("pane_1"),
        ]))
        #expect(try Self.generated(StateResourceClient.stashRestoreRequest("stash_1", members: nil, target: .here, pane: nil))
            == Self.handBuilt("stash.restore", ["stash": .string("stash_1"), "target": .string("here")]))
        #expect(try Self.generated(V2StashDeleteRequest(members: ["m_1"], stash: "stash_1"))
            == Self.handBuilt("stash.delete", ["stash": .string("stash_1"), "members": .array([.string("m_1")])]))
        #expect(try Self.generated(V2StashDeleteRequest(stash: "stash_1"))
            == Self.handBuilt("stash.delete", ["stash": .string("stash_1")]))
        let groups = [
            StateResourceClient.StashImportGroup(name: "Reading", pages: [
                .init(url: "https://example.com/a", title: "A"), .init(url: "https://example.com/b", title: nil),
            ]),
            StateResourceClient.StashImportGroup(name: nil, pages: []),
        ]
        #expect(try Self.generated(StateResourceClient.oneTabImportRequest(groups, engine: "cef"))
            == Self.handBuilt("stash.import", [
                "source": .string("onetab"), "engine": .string("cef"), "groups": .array([
                    .object(["name": .string("Reading"), "tabs": .array([
                        .object(["url": .string("https://example.com/a"), "title": .string("A")]),
                        .object(["url": .string("https://example.com/b")]),
                    ])]),
                    .object(["tabs": .array([])]),
                ]),
            ]))
        #expect(try Self.generated(StateResourceClient.oneTabImportRequest([], engine: nil))
            == Self.handBuilt("stash.import", ["source": .string("onetab"), "groups": .array([])]))
    }

    @Test func bulkCloseAndRetentionPrune() throws {
        #expect(try Self.generated(StateResourceClient.bulkCloseRequest(.screen, ids: [Self.id("screen_1")], endTerminals: false))
            == Self.handBuilt("layout.bulk", [
                "verb": .string("close"), "level": .string("screen"), "selector": .string("selection"),
                "ids": .array([.string("screen_1")]), "end_terminals": .bool(false),
            ]))
        #expect(try Self.generated(StateResourceClient.pruneRequest(ClosedRetention.Prune(beforeMs: 1_700_000_000_000,
                                                                                          keepNewest: 50)))
            == Self.handBuilt("closed.delete", [
                "all": .bool(true), "before_ms": .string("1700000000000"), "keep_newest": .number(50),
            ]))
        #expect(try Self.generated(StateResourceClient.pruneRequest(ClosedRetention.Prune(beforeMs: nil, keepNewest: 10)))
            == Self.handBuilt("closed.delete", ["all": .bool(true), "keep_newest": .number(10)]))
    }

    @Test func checklist() throws {
        #expect(try Self.generated(StateResourceClient.checklistAddRequest(Self.id("ws_1"), text: "ship it", index: 2))
            == Self.handBuilt("workspace_checklist.add", [
                "workspace": .string("ws_1"), "text": .string("ship it"), "origin": .string("user"), "index": .number(2),
            ]))
        #expect(try Self.generated(StateResourceClient.checklistAddRequest(Self.id("ws_1"), text: "ship it", index: nil))
            == Self.handBuilt("workspace_checklist.add", [
                "workspace": .string("ws_1"), "text": .string("ship it"), "origin": .string("user"),
            ]))
        // Only the fields that change; attachments go as the whole list, a new one without an id.
        let update = StateResourceClient.checklistUpdateRequest(
            Self.id("ws_1"), item: "chk_b", state: .inProgress,
            attachments: [WorkspaceChecklistAttachment(id: "att_1", path: "/tmp/shot.png", name: "shot.png"),
                          WorkspaceChecklistAttachment(path: "/tmp/new.png")])
        #expect(try Self.generated(update) == Self.handBuilt("workspace_checklist.update", [
            "workspace": .string("ws_1"), "item": .string("chk_b"), "state": .string("in_progress"),
            "attachments": .array([
                .object(["id": .string("att_1"), "path": .string("/tmp/shot.png"), "name": .string("shot.png")]),
                .object(["path": .string("/tmp/new.png"), "name": .string("new.png")]),
            ]),
        ]))
        #expect(try Self.generated(StateResourceClient.checklistUpdateRequest(Self.id("ws_1"), item: "chk_b", text: "t", index: 1))
            == Self.handBuilt("workspace_checklist.update", [
                "workspace": .string("ws_1"), "item": .string("chk_b"), "text": .string("t"), "index": .number(1),
            ]))
        #expect(try Self.generated(V2WorkspaceChecklistRemoveRequest(workspace: StateResourceClient.selector(Self.id("ws_1")),
                                                                     item: "chk_b"))
            == Self.handBuilt("workspace_checklist.remove", ["workspace": .string("ws_1"), "item": .string("chk_b")]))
    }

    @Test func browserEmulation() throws {
        #expect(try Self.generated(V2BrowserDevicesListRequest()) == Self.handBuilt("browser.devices.list", [:], keyed: false))
        #expect(try Self.generated(StateResourceClient.emulateRequest(Self.id("tab_1"), device: "iPhone 15", orientation: "landscape"))
            == Self.handBuilt("browser.tab.emulate", [
                "tab": .string("tab_1"), "device": .string("iPhone 15"), "orientation": .string("landscape"),
            ]))
        #expect(try Self.generated(StateResourceClient.emulateRequest(Self.id("tab_1"), device: nil, orientation: nil))
            == Self.handBuilt("browser.tab.emulate", ["tab": .string("tab_1")]))
        #expect(try Self.generated(V2BrowserTabEmulateRequest(tab: StateResourceClient.selector(Self.id("tab_1")), fit: "16:9"))
            == Self.handBuilt("browser.tab.emulate", ["tab": .string("tab_1"), "fit": .string("16:9")]))
        #expect(try Self.generated(V2BrowserTabEmulateClearRequest(tab: StateResourceClient.selector(Self.id("tab_1"))))
            == Self.handBuilt("browser.tab.emulate.clear", ["tab": .string("tab_1")]))
    }

    @Test func agentCLIJobWaitExit() throws {
        let request = AgentCLIJobCarrier.waitExitRequest(machine: Self.id("machine_a"), session: Self.id("session_b"),
                                                         terminal: Self.id("term_1"))
        #expect(try Self.generated(request) == Self.handBuilt("terminal.wait_exit", [
            "machine": .string("machine_a"), "session": .string("session_b"), "terminal": .string("term_1"),
            "timeout_ms": .string("5000"),
        ], keyed: false))
    }

    /// The line DaemonConnection sends for a generated request: its operation names the
    /// transport's wait and trace, and its bytes are the envelope builder's.
    @Test func generatedLinesAreDaemonResourceLines() throws {
        let line = ResourceRequestLine(id: 4, request: V2WindowRecordListRequest())
        #expect(line.operation == "window_record.list")
        #expect(try line.lineData() == line.line())
        let envelope = ResourceRequestEnvelope(id: 4, operation: "window_record.list", params: [:], idempotencyKey: nil)
        #expect(envelope.operation == line.operation)
        #expect(try envelope.lineData() == line.lineData())
    }

    @Test func fieldUpdatesMapToTheGeneratedSpelling() {
        #expect(FieldUpdate<String>.unchanged.resourceField { $0 } == .unchanged)
        #expect(FieldUpdate<String>.clear.resourceField { $0 } == .clear)
        #expect(FieldUpdate<WorkspaceTaskStatus>.set(.review).resourceField { $0.rawValue } == .set("review"))
    }
}
