import Foundation
import Testing
@testable import CmuxNextDaemon

/// The next Cmd-N's workspace, reserved before the key (STATUS 15250): its model holds its screen and stays out of the
/// store's visible records until the press's create intent shows that same model, under the press's name.
@MainActor
struct ReservedWorkspaceTests {
    private static let pane = PaneID(rawValue: 3)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func reserve(in store: DaemonStore) -> ReservedWorkspace {
        let tab = ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
        return store.reserveWorkspace(ProvisionalWorkspace(key: WorkspaceKey.generate(), name: "", tab: tab))
    }

    @Test func aReservationHoldsItsScreenAndShowsNothing() {
        let store = Self.store()
        let reserved = Self.reserve(in: store)
        #expect(reserved.model.screens.count == 1)
        #expect(reserved.model.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [reserved.provisional.tab.surface])
        #expect(store.workspaces.count == 1, "a reservation is not a listed workspace")
        #expect(store.workspace(id: reserved.provisional.key.rawValue) == nil)
        #expect(store.tabsBySurface[reserved.provisional.tab.surface] == nil, "a reservation is not indexed")
        #expect(store.reserves(reserved.model))
        // A view mapped from the reserved model finds its pane in the model itself (the store indexes none of it).
        #expect(store.pane(reserved.provisional.pane) == nil)
        #expect(reserved.model.pane(reserved.provisional.pane)?.tabs.map(\.surface) == [reserved.provisional.tab.surface])
    }

    @Test func thePressShowsTheReservedModelUnderItsName() throws {
        let store = Self.store()
        let reserved = Self.reserve(in: store)
        store.intend(.createWorkspace(provisional: reserved.provisional.named("2"), index: nil), transaction: .generate())

        let shown = try #require(store.workspace(id: reserved.provisional.key.rawValue))
        #expect(shown === reserved.model, "the press shows the model its window built a view on")
        #expect(shown.name == "2")
        #expect(shown.screens.count == 1, "the screen it held is not appended twice")
        #expect(store.tabsBySurface[reserved.provisional.tab.surface] != nil)
        #expect(store.reservedWorkspace == nil, "the press took the reservation")
        #expect(!store.reserves(reserved.model))
    }

    /// The prune of settled creates (every overlay lift) keeps only keys a pending create names: a reservation is none.
    @Test func aDaemonEventKeepsTheReservation() {
        let store = Self.store()
        let reserved = Self.reserve(in: store)
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base]))
        #expect(store.reservedWorkspace?.model === reserved.model)
    }

    /// Every overlay lift and restore shows the same model with one screen; a refusal removes it exactly.
    @Test func liftsKeepOneScreenAndARefusalRemovesIt() throws {
        let store = Self.store()
        let reserved = Self.reserve(in: store)
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: reserved.provisional.named("2"), index: nil), transaction: transaction)
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base]))
        let shown = try #require(store.workspace(id: reserved.provisional.key.rawValue))
        #expect(shown === reserved.model)
        #expect(shown.screens.count == 1)
        store.rejectIntent(transaction)
        #expect(store.workspace(id: reserved.provisional.key.rawValue) == nil)
        #expect(store.workspaces.count == 1)
    }

    @Test func aPressUsesTheReservationOnlyWhenPlain() {
        let store = Self.store(), home = Self.store()
        #expect(store.reservedWorkspaceUse(plain: true, home: store) == .miss(elsewhere: false))
        let reserved = Self.reserve(in: home)
        #expect(store.reservedWorkspaceUse(plain: true, home: home) == .miss(elsewhere: true))
        #expect(home.reservedWorkspaceUse(plain: false, home: home) == .notPlain)
        #expect(home.reservedWorkspaceUse(plain: false, home: home).span == nil)
        let use = home.reservedWorkspaceUse(plain: true, home: home)
        #expect(use == .hit(reserved.provisional.key))
        #expect(use.span == "cmdN.reserved.hit")
    }

    @Test func aReleaseReturnsTheReservationOnce() {
        let store = Self.store()
        let reserved = Self.reserve(in: store)
        #expect(store.releaseReservedWorkspace(.pressure)?.model === reserved.model)
        #expect(store.reservedWorkspace == nil)
        #expect(store.releaseReservedWorkspace(.pressure) == nil)
        #expect(ReservedWorkspaceRelease.pressure.span == "cmdN.reserved.released.pressure")
    }

    /// Cmd-N's first tab request, moved out of `AgentTabStore.showWorkspace` with the same bytes: the agent session,
    /// the workspace, the origin, the mutation id and the transaction, and nothing else.
    @Test func theFirstTabRequestKeepsItsFields() throws {
        let record = AgentSessionRef(host: "install:test", hostName: nil)
        let transaction = ClientTransactionID.generate()
        let moved = NewConversationTabRequest.firstAgentTab(record, in: WorkspaceHandle(rawValue: 7), origin: "cmux-next", mutationID: "m-1",
                                                            transaction: transaction)
        var before = NewConversationTabRequest(agentSession: record, workspace: WorkspaceHandle(rawValue: 7), origin: "cmux-next", mutationID: "m-1")
        before.transaction = transaction
        func fields(_ request: NewConversationTabRequest) throws -> NSDictionary {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
        }
        #expect(try fields(moved) == fields(before))
        #expect(try fields(moved).allKeys.count == 5, "agent session, workspace, origin, mutation id, transaction")
        #expect(moved.pane == nil && moved.split == nil && moved.page == nil)
    }

    @Test func aCreatedTabsKeyIsItsResourceElseItsSurface() throws {
        func response(_ json: String) throws -> NewConversationTabRequest.Response {
            try JSONDecoder().decode(NewConversationTabRequest.Response.self, from: Data(json.utf8))
        }
        #expect(try response(#"{"surface": 12, "replayed": false, "tab_resource_id": "tab_9"}"#).tabKey == "tab_9")
        #expect(try response(#"{"surface": 12, "replayed": false}"#).tabKey == "surface:12")
    }

    /// The pin before a create, moved out of `WorkspaceSpawner` with the same answer: only with a room and a session.
    @Test func aCreatePinsOnlyWithARoomAndASession() {
        let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-00000000000b"), room = ProfileID(rawValue: "work")
        let pin = PinWorkspaceRequest.beforeCreate(session: "s-1", key: key, room: room)
        #expect(pin?.sessionID == "s-1" && pin?.workspaceKey == key && pin?.profile == room)
        #expect(PinWorkspaceRequest.beforeCreate(session: nil, key: key, room: room) == nil)
        #expect(PinWorkspaceRequest.beforeCreate(session: "s-1", key: key, room: nil) == nil)
    }
}
