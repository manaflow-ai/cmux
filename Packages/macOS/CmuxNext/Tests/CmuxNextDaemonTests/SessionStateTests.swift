import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon's state resources over `session.events`: stream lines decode
/// into the mirror, and the store lays the mirror over its records.
@MainActor @Suite struct SessionStateTests {
    // Ids from Fixtures/list-workspaces.json.
    nonisolated static let workspace = "ws_b287f9cec6d7f869da16b84b4b34a56f"
    nonisolated static let screen = "screen_108542859012b9e35b7a1b73a47ebe10"
    nonisolated static let screen2 = "screen_42351ba87372bc02f96d71f8c707ef7e"
    nonisolated static let tab = "tab_294c0b000c0d050151bcf9ab4b0de6d0"
    nonisolated static let terminal = "term_e4d7ac5cb97baa6f67fe345cb27f19cf"

    nonisolated static func item(_ body: String) -> String {
        #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"stream_1","sequence":"1","item":\#(body)}"#
    }

    nonisolated static let closedTab = #"{"id":"closed_1","kind":"tab","name":"logs","workspace_id":"\#(workspace)","pane_id":"pane_p","index":2,"closed_at_ms":"1790000000000","screens":[{"name":null,"tabs":[{"kind":"terminal","name":"logs","cwd":"/tmp","url":null,"browser_profile_id":null,"pinned":false}]}]}"#

    nonisolated static let snapshot = item(#"""
    {"kind":"snapshot","cursor":{"generation":"g","revision":"4"},"reset_reason":"initial","snapshot":{
      "workspaces":[{"id":"\#(workspace)","session_id":"session_s","name":"beta","index":0,"focused":true,"extra":{"ephemeral":true}}],
      "screens":[{"id":"\#(screen)","workspace_id":"\#(workspace)","name":null,"index":0,"focused":true,"layout":{},"extra":{"pinned":true,"color":"green","screen_group_id":"sgrp_1"}}],
      "panes":[],
      "tabs":[{"id":"\#(tab)","pane_id":"pane_p","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"\#(terminal)","extra":{"zoom":1.5}}],
      "terminals":[{"id":"\#(terminal)","tab_id":"\#(tab)","tab_ids":["\#(tab)"],"title":"t","cols":80,"rows":24,"running":true,"lifecycle":"running","extra":{"progress":{"state":"normal","value":40}}}],
      "browsers":[],"clients":[],"notifications":[],"agents":[],"frontend_projections":[],"sidebar_views":[],
      "cursor":{"generation":"g","revision":"4"},
      "extra":{"state":{"tab_groups":[],"saved_tab_groups":[],"workspace_groups":[],"workspace_placements":[],"rooms":[],
        "screen_groups":[{"id":"sgrp_1","workspace_id":"\#(workspace)","name":"Build","color":"orange","collapsed":false,"screen_ids":["\#(screen)"]}],
        "closed":[\#(closedTab)],
        "workspace_status":[{"workspace_id":"\#(workspace)","entries":[{"key":"build","text":"Building","icon":null,"color":null,"updated_at_ms":"1"}],"progress":{"value":0.25,"label":"step 1","updated_at_ms":"1"},"log_count":1,"last_log":null}]}}
    }}
    """#)

    private func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    private func event(_ line: String) -> DaemonEvent {
        DaemonEvent.decode(name: LineTransport.streamEvent, line: Data(line.utf8))
    }

    @Test func snapshotDecodesEveryStateTheAppMirrors() throws {
        guard case .sessionState(.snapshot(let mirror)) = event(Self.snapshot) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(mirror.ephemeralWorkspaces == [ResourceID(rawValue: Self.workspace)])
        #expect(mirror.closed.map(\.id) == ["closed_1"])
        #expect(mirror.closed.first?.tabs.first?.cwd == "/tmp")
        #expect(mirror.closed.first?.closedAtMs == 1_790_000_000_000)
        #expect(mirror.workspaceStatus[ResourceID(rawValue: Self.workspace)]?.line == "Building")
        #expect(mirror.screens[ResourceID(rawValue: Self.screen)] == .init(pinned: true, color: "green", group: "sgrp_1"))
        #expect(mirror.tabs[ResourceID(rawValue: Self.tab)]?.zoom == 1.5)
        #expect(mirror.terminalProgress[ResourceID(rawValue: Self.terminal)] == TerminalProgressReport(state: .normal, value: 40))
    }

    @Test func aSnapshotWithoutStateIsNotAStateItem() {
        let old = Self.item(#"{"kind":"snapshot","cursor":{"generation":"g","revision":"1"},"snapshot":{"workspaces":[],"screens":[],"tabs":[],"terminals":[],"cursor":{"generation":"g","revision":"1"}}}"#)
        #expect(SessionStreamItem.decode(Data(old.utf8)) == nil)
        let end = #"{"protocol":"cmux.protocol/2","type":"stream_end","stream_id":"stream_1","reason":"gap"}"#
        #expect(event(end) == .sessionState(.ended(reason: "gap")))
    }

    @Test func storeLaysTheStateOverItsRecords() throws {
        let store = try loadedStore()
        #expect(!store.servesStateResources)
        // The daemon's `identify` says it serves the state resources.
        store.noteHandshake(DaemonCompatibilityTests.identity([DaemonCapabilities.shared.stateResources]))
        #expect(store.servesStateResources)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event(Self.snapshot))])
        let workspace = try #require(store.workspaces.first { $0.resourceID?.rawValue == Self.workspace })
        #expect(workspace.ephemeral)
        #expect(workspace.status?.line == "Building")
        #expect(workspace.status?.progress?.value == 0.25)
        let screen = try #require(workspace.screens.first { $0.resourceID?.rawValue == Self.screen })
        #expect(screen.pinned && screen.color == "green" && screen.group == "sgrp_1")
        #expect(workspace.screenGroups.map(\.id.rawValue) == ["sgrp_1"])
        #expect(workspace.screenGroups.first?.screens == [screen.handle])
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.resourceID?.rawValue == Self.tab })
        #expect(tab.zoom == 1.5)
        #expect(tab.progress == TerminalProgressReport(state: .normal, value: 40))
        #expect(store.closedItems.map(\.id) == ["closed_1"])

        // A raw resync must not wipe the state the raw tree does not carry.
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        #expect(screen.pinned && screen.color == "green")
        #expect(workspace.screenGroups.count == 1)
    }

    @Test func deltasUpdateAndRemoveStateEvenBehindATreeSnapshot() throws {
        let store = try loadedStore()
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event(Self.snapshot))])
        // A later tree snapshot's barrier never drops session items.
        store.snapshotBarrier = 100
        let delta = Self.item(#"""
        {"kind":"delta","cursor":{"generation":"g","revision":"6"},"previous_revision":"4","revision":"6","changes":[
          {"kind":"state_delete","sequence":0,"resource":"closed","id":"closed_1"},
          {"kind":"state_upsert","sequence":1,"resource":"closed","id":"closed_2","value":{"id":"closed_2","kind":"workspace","name":"w","workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":"5","screens":[]}},
          {"kind":"state_delete","sequence":2,"resource":"workspace_status","id":"\#(Self.workspace)"},
          {"kind":"upsert","sequence":3,"resource":"terminal","id":"\#(Self.terminal)","value":{"id":"\#(Self.terminal)","tab_id":null,"tab_ids":[],"title":"t","cols":80,"rows":24,"running":true,"lifecycle":"running"}},
          {"kind":"upsert","sequence":4,"resource":"screen","id":"\#(Self.screen)","value":{"id":"\#(Self.screen)","workspace_id":"\#(Self.workspace)","name":null,"index":0,"focused":true,"layout":{},"extra":{"color":"red"}}},
          {"kind":"state_delete","sequence":5,"resource":"screen_group","id":"sgrp_1"},
          {"kind":"future_kind","sequence":6,"resource":"x","id":"y"}
        ]}
        """#)
        store.apply(batch: [DaemonEventEnvelope(sequence: 50, event: event(delta))])
        #expect(store.closedItems.map(\.id) == ["closed_2"])
        let workspace = try #require(store.workspaces.first { $0.resourceID?.rawValue == Self.workspace })
        #expect(workspace.status == nil)
        #expect(workspace.screenGroups.isEmpty)
        let screen = try #require(workspace.screens.first { $0.resourceID?.rawValue == Self.screen })
        #expect(!screen.pinned && screen.color == "red" && screen.group == nil)
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.resourceID?.rawValue == Self.tab })
        #expect(tab.progress == nil)
    }

    @Test func closedHistoryKeepsNewestFirstAndBounded() {
        var mirror = SessionStateMirror()
        for index in 0..<60 {
            mirror.apply(.closed(ClosedItem(id: "closed_\(index)", kind: .tab, closedAtMs: UInt64(index))))
        }
        #expect(mirror.closed.count == SessionStateMirror.closedLimit)
        #expect(mirror.closed.first?.id == "closed_59")
        #expect(mirror.closed.last?.id == "closed_10")
    }
}
