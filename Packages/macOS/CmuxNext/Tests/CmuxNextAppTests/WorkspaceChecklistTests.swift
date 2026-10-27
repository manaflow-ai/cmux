import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Workspace checklists (`workspace-checklist-v1`): the daemon keeps each workspace's items
/// (text, todo / in progress / done, image attachments) and publishes them as the
/// `workspace_checklist` state resource. The store lays them on the workspace, the sidebar row's
/// hover card lists them, the Todo page edits them, and the nine checklist actions (palette,
/// workspace menu, Cmd-Return, CLI and MCP by `cmux action run`) run one shared edit path.
@MainActor @Suite(.serialized)
struct WorkspaceChecklistTests {
    static let ids: [ActionID] = [
        "palette.addWorkspaceChecklistItem", "toggleChecklistItemComplete", "palette.openWorkspaceTodoPane",
        "checklistEditItem", "checklistMarkInProgress", "checklistCompleteItem", "checklistRemoveItem",
        "checklistOpenAsPane", "checklistAttachImages",
    ]

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// Advertises `capabilities` on this Mac's daemon.
    static func handshake(_ store: DaemonStore, capabilities: [String]) throws {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
    }

    static let checklistJSON = #"""
    {"workspace_id":"ws_1","items":[
      {"id":"chk_a","text":"read the issue","state":"done","origin":"user","attachments":[],
       "created_at_ms":"1","updated_at_ms":"2"},
      {"id":"chk_b","text":"write the test","state":"in_progress","origin":"agent",
       "attachments":[{"id":"att_1","path":"/tmp/shot.png","name":"shot.png"}],
       "created_at_ms":"1","updated_at_ms":"2"},
      {"id":"chk_c","text":"ship it","state":"todo","origin":"user","attachments":[],
       "created_at_ms":"1","updated_at_ms":"2"}
    ]}
    """#

    /// A store with workspace `ws_1` and the checklist above from a `session.events` snapshot.
    static func store() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), resourceID: ResourceID(rawValue: "ws_1"), name: "w"),
        ]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":[{"id":"ws_1"}],"#
            + #""extra":{"state":{"workspace_checklist":["# + checklistJSON + "]}}}}}"
        let item = try #require(SessionStreamItem.decode(Data(line.utf8)))
        store.session.apply(item, in: store)
        return store
    }

    // MARK: The state resource

    @Test func aSessionSnapshotAndItsDeltasCarryEachWorkspacesChecklist() throws {
        let store = try Self.store()
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.checklist.map(\.text) == ["read the issue", "write the test", "ship it"])
        #expect(workspace.checklist.map(\.state) == [.done, .inProgress, .todo])
        #expect(workspace.checklist[1].origin == .agent)
        #expect(workspace.checklist[1].attachments == [WorkspaceChecklistAttachment(id: "att_1", path: "/tmp/shot.png", name: "shot.png")])

        let upsert = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_checklist","id":"ws_1","value":{"workspace_id":"ws_1","items":[{"id":"chk_c","text":"ship it","state":"done","origin":"user","attachments":[],"created_at_ms":"1","updated_at_ms":"3"}]}}]}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(upsert.utf8))), in: store)
        #expect(workspace.checklist.map(\.id) == ["chk_c"])
        #expect(workspace.checklist.first?.state == .done)

        let delete = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_delete","resource":"workspace_checklist","id":"ws_1"}]}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(delete.utf8))), in: store)
        #expect(workspace.checklist.isEmpty)
    }

    // MARK: Availability

    @Test func checklistActionsWaitForADaemonThatKeepsChecklists() {
        let services = Self.services()
        AppActions.bind(services)
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) != nil, "\(id) runs without workspace-checklist-v1")
        }
    }

    @Test func checklistActionsRunOnADaemonThatKeepsChecklists() throws {
        let services = Self.services()
        AppActions.bind(services)
        try Self.handshake(services.machines.local.store, capabilities: ["state-resources-v1", "workspace-checklist-v1"])
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    // MARK: The one edit path

    @Test func eachActionMakesItsEdit() throws {
        let items = try #require(try Self.store().workspaces.first).checklist
        func edit(_ id: ActionID, _ arguments: [String: ActionValue] = [:]) throws -> WorkspaceChecklistEdit {
            try WorkspaceChecklistEdit.make(for: id, invocation: ActionInvocation(arguments: arguments), items: items)
        }
        #expect(try edit("palette.addWorkspaceChecklistItem", ["text": .string("  review  ")]) == .add(text: "review"))
        // Without an item, the current item: the first in progress, else the first to do.
        #expect(try edit("toggleChecklistItemComplete") == .update(item: "chk_b", state: .done))
        #expect(try edit("toggleChecklistItemComplete", ["item": .string("chk_a")]) == .update(item: "chk_a", state: .todo),
                "a done item toggles back to do")
        #expect(try edit("checklistCompleteItem", ["item": .string("chk_c")]) == .update(item: "chk_c", state: .done))
        #expect(try edit("checklistMarkInProgress", ["item": .string("chk_c")]) == .update(item: "chk_c", state: .inProgress))
        #expect(try edit("checklistEditItem", ["item": .string("chk_c"), "text": .string("ship it today")])
            == .update(item: "chk_c", text: "ship it today"))
        #expect(try edit("checklistRemoveItem", ["item": .string("chk_a")]) == .remove(item: "chk_a"))
        #expect(try edit("checklistAttachImages", ["item": .string("chk_b"), "path": .string("/tmp/more.png")])
            == .update(item: "chk_b", attachments: items[1].attachments + [WorkspaceChecklistAttachment(path: "/tmp/more.png")]),
                "a new image joins the ones the item has")
        #expect(throws: ActionFailure.self) { try edit("palette.addWorkspaceChecklistItem", ["text": .string("   ")]) }
        #expect(throws: ActionFailure.self) { try edit("checklistRemoveItem", ["item": .string("chk_missing")]) }
        #expect(throws: ActionFailure.self, "an empty checklist has no current item") {
            try WorkspaceChecklistEdit.make(for: "checklistCompleteItem", invocation: ActionInvocation(), items: [])
        }
    }

    // MARK: Surfaces

    @Test func theSidebarRowAndItsHoverCardListTheChecklist() throws {
        let workspace = try #require(try Self.store().workspaces.first)
        let row = SidebarMapping.shared.row(workspace, machine: .local)
        #expect(row.checklist.map(\.text) == ["read the issue", "write the test", "ship it"])
        #expect(row.checklist.map(\.state) == [.done, .inProgress, .todo])
        let facts = WorkspaceHoverCardContent.make(row, machine: nil, now: Date()).facts.filter { $0.kind == "checklist" }
        #expect(facts.map(\.text) == ["read the issue", "write the test", "ship it"])
        #expect(Set(facts.compactMap(\.mark)).count == 3, "each state draws its own mark")
    }

    @Test func theTodoPageListsTheItemsAndEditsThroughTheActions() throws {
        let services = Self.services()
        AppActions.bind(services)
        #expect(services.pages.provider(.workspaceTodo) != nil, "the Todo page is registered at launch")
        let store = try Self.store()
        var runs: [(ActionID, ActionInvocation)] = []
        let model = WorkspaceTodoPageModel(workspaceID: "w1", workspace: { store.workspace(id: $0) },
                                           perform: { runs.append(($0, $1)) })
        #expect(model.items.map(\.text) == ["read the issue", "write the test", "ship it"])
        model.add("  review  ")
        model.toggle("chk_c")
        model.setState("chk_c", .inProgress)
        model.edit("chk_c", text: "ship it today")
        model.remove("chk_a")
        model.attachImages("chk_b")
        #expect(runs.map(\.0) == ["palette.addWorkspaceChecklistItem", "toggleChecklistItemComplete", "checklistMarkInProgress",
                                  "checklistEditItem", "checklistRemoveItem", "checklistAttachImages"])
        #expect(runs.allSatisfy { $0.1.target == ActionTargetRef(kind: .workspace, id: "w1") })
        #expect(runs[0].1["text"]?.stringValue == "  review  ")
        #expect(runs[1].1["item"]?.stringValue == "chk_c")
        #expect(runs[3].1["text"]?.stringValue == "ship it today")
    }
}
