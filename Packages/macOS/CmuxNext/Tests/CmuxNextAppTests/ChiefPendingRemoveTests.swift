import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// A Chief just dragged in, before the daemon answers (#23933 review rounds 3 to 5): it draws at once and comes off
/// through the App's action; one Chief; a refused remove keeps it; no edit until its echo; no other built-in draws early.
@MainActor @Suite(.serialized)
struct ChiefPendingRemoveTests {
    /// The sidebar document: the top rows (Home and the App Store, as the default layout has them), no Chief.
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_top", "kind": {"type": "custom"}, "region": "top"}],
     "items": [
       {"id": "itm_home", "section": "sec_top", "order": "a", "body": {"type": "app", "id": "cmux/home"}},
       {"id": "itm_app_store", "section": "sec_top", "order": "b", "body": {"type": "app", "id": "cmux/app-store"}}
     ]}
    """.utf8)

    /// The App's services and actions over a loaded document whose daemon never answers, made the current one
    /// (`end` puts the previous one back).
    static func pending(refusingRemoves: Bool = false) async throws -> (AppServices, SidebarDocStore, end: () -> Void) {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let remote: any SidebarDocRemote = refusingRemoves ? RefusingRemoves(document: document)
            : SidebarGroupDragRailTests.Remote(document: document)
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        store.show(live: [])
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        return (services, store, { SidebarDocStore.current = previous })
    }

    static let addChief = [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"]] as [String: Any],
                            "to": ["section": "sec_top"]]] as [[String: Any]]

    /// The items the sidebar draws (its projection's sections), the Chief's among them.
    static func drawn(_ store: SidebarDocStore) -> [LayoutItem] {
        store.projection(live: [])?.layout.sections.flatMap(\.items) ?? []
    }

    /// `target`: the item's id (a drag out, Remove from Sidebar) or the built-in's name (the App Store card).
    @Test(arguments: ["itm_chief", "chief"])
    func aChiefAddedAndNotYetConfirmedComesOffThroughTheAction(target: String) async throws {
        let (services, store, end) = try await Self.pending()
        defer { end() }
        try store.sendChecked(ops: Self.addChief, title: "Add", undoable: false)
        try #require(store.placesItem(with: .builtIn(.chief)), "the added Chief does not count as placed")
        #expect(Self.drawn(store).map(\.ref).contains(.builtIn(.chief)), "the sidebar does not draw the Chief added before the daemon answered")

        let ran = services.registry.perform("sidebar.item.removeEverywhere",
                                            invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: target), origin: .user))
        #expect(ran, "Remove from Sidebar did not run for the pending Chief (\(target))")
        #expect(!store.placesItem(with: .builtIn(.chief)), "the pending Chief stayed placed after its Remove (\(target))")
    }

    /// Two adds before the daemon answers the first (two quick drags in, or Get in two windows): one Chief.
    @Test func aSecondAddBeforeTheDaemonAnswersAddsNoSecondChief() async throws {
        let (services, store, end) = try await Self.pending()
        defer { end() }
        let add = ActionInvocation(arguments: ["item": .string("chief")], origin: .user)
        _ = services.registry.perform("sidebar.item.add", invocation: add)
        try #require(store.placesItem(with: .builtIn(.chief)), "the first add placed no Chief")
        _ = services.registry.perform("sidebar.item.add", invocation: add)
        let chiefs = Self.drawn(store).filter { $0.ref == .builtIn(.chief) }
        #expect(chiefs.count == 1, "two adds before the daemon answered drew \(chiefs.count) Chiefs")
    }

    /// An edit of the pending Chief (its label on a line) waits for its echo: the menu does not offer it, and the edit
    /// is refused (nothing is sent), never sent and lost or drawn from a stale record. A confirmed item keeps it.
    @Test func anEditOfThePendingChiefIsNotOfferedUntilItsEcho() async throws {
        let (_, store, end) = try await Self.pending()
        defer { end() }
        try store.sendChecked(ops: Self.addChief, title: "Add", undoable: false)
        let chief = try #require(Self.drawn(store).first { $0.ref == .builtIn(.chief) }, "the pending Chief is not drawn")
        #expect(SidebarBridge.pendingEdits(chief.id).contains("sidebar.item.toggleLabel"), "the menu offers Show/Hide Label on the pending Chief")
        #expect(SidebarBridge.pendingEdits(LayoutItemID("itm_home")).isEmpty, "a confirmed item lost its label edit")
        let layout = try #require(store.projection(live: [])?.layout)
        #expect(throws: SidebarDocStore.LayoutOpGap.self, "an edit of the pending Chief was planned (sent before its add's echo)") {
            try store.docOps(for: [.itemUpdate(chief.id, showsLabel: !chief.showsLabel)], layout: layout)
        }
    }

    /// Only the Chief draws before its echo: another built-in (Settings) draws at its echo, as before.
    @Test func anotherBuiltInDrawsAtItsEcho() async throws {
        let (_, store, end) = try await Self.pending()
        defer { end() }
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_settings", "body": ["type": "builtin", "id": "settings"]] as [String: Any],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        #expect(!Self.drawn(store).map(\.ref).contains(.builtIn(.settings)), "a pending Settings item draws before its echo")
    }

    /// The pending Chief's remove is refused: the mirror puts the Chief back, and the sidebar draws it again, placed;
    /// a second add then adds nothing (the first add's echo will place the one Chief).
    @Test func aRefusedRemoveOfThePendingChiefKeepsIt() async throws {
        let (services, store, end) = try await Self.pending(refusingRemoves: true)
        defer { end() }
        _ = services.registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string("chief")], origin: .user))
        try #require(store.placesItem(with: .builtIn(.chief)), "the add placed no Chief")
        _ = services.registry.perform("sidebar.item.removeEverywhere",
                                      invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: "chief"), origin: .user))
        #expect(Self.drawn(store).allSatisfy { $0.ref != .builtIn(.chief) }, "the removed Chief still draws before the refusal")
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { store.placesItem(with: .builtIn(.chief)) }
        #expect(store.placesItem(with: .builtIn(.chief)), "the Chief whose remove was refused counts as not placed")
        #expect(Self.drawn(store).filter { $0.ref == .builtIn(.chief) }.count == 1, "the Chief whose remove was refused does not draw")
        let sent = store.lastIntentKey
        _ = services.registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string("chief")], origin: .user))
        #expect(store.lastIntentKey == sent, "a second add was sent for the Chief still placed")
        #expect(Self.drawn(store).filter { $0.ref == .builtIn(.chief) }.count == 1, "two Chiefs draw")
    }

    /// A daemon that refuses every change that removes, and answers nothing else.
    @MainActor final class RefusingRemoves: SidebarDocRemote {
        struct Refused: Error {}
        let document: Data
        init(document: Data) { self.document = document }
        var isAvailable: Bool { true }
        func get() async throws -> Data { document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try await unanswered() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            if String(decoding: ops, as: UTF8.self).contains("remove") { throw Refused() }
            return try await unanswered()
        }
        private func unanswered() async throws -> SidebarDocReply {
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }
}
