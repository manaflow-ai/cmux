import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// A Chief just dragged in, before the daemon answers (#23933 review rounds 3 to 5): it draws at once and comes off
/// through the App's action; one Chief; a refused remove keeps it; no edit until its echo; no other built-in draws early.
@MainActor @Suite(.serialized)
struct ChiefPendingRemoveTests {
    /// The sidebar document: the top rows (Home and the App Store, as the default layout has them), then `chief`.
    static func document(chief: String = "") -> Data {
        Data("""
        {"revision": "1",
         "sections": [{"id": "sec_top", "kind": {"type": "custom"}, "region": "top"}],
         "items": [
           {"id": "itm_home", "section": "sec_top", "order": "a", "body": {"type": "app", "id": "cmux/home"}},
           {"id": "itm_app_store", "section": "sec_top", "order": "b", "body": {"type": "app", "id": "cmux/app-store"}}\(chief)
         ]}
        """.utf8)
    }

    /// A confirmed Chief at the end of the top rows, its label hidden.
    static let hiddenLabelChief = #", {"id": "itm_chief", "section": "sec_top", "order": "c", "shows_label": false, "body": {"type": "builtin", "id": "chief"}}"#

    /// The App's services and actions over a loaded document whose daemon never answers, made the current one
    /// (`end` puts the previous one back).
    static func pending(document: Data = Self.document(), refusingRemoves: Bool = false,
                        remote: (any SidebarDocRemote)? = nil) async throws -> (AppServices, SidebarDocStore, end: () -> Void) {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let remote: any SidebarDocRemote = remote ?? (refusingRemoves ? RefusingRemoves(document: document)
            : SidebarGroupDragRailTests.Remote(document: document))
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

    /// An edit of the pending Chief (its label on a line) waits for its echo: the item menu does not offer it, and the
    /// edit is refused (nothing is sent), never sent and lost or drawn from a stale record. The echo brings it back.
    @Test func anEditOfThePendingChiefIsNotOfferedUntilItsEcho() async throws {
        let (services, store, end) = try await Self.pending()
        defer { end() }
        let bridge = try Self.bridge(services)
        try store.sendChecked(ops: Self.addChief, title: "Add", undoable: false)
        let chief = try #require(Self.drawn(store).first { $0.ref == .builtIn(.chief) }, "the pending Chief is not drawn")
        #expect(!Self.offersLabel(bridge, chief.id), "the menu offers Show/Hide Label on the pending Chief")
        #expect(Self.offersLabel(bridge, LayoutItemID("itm_home")), "a confirmed item lost its label edit")
        try Self.expectNoLabelEdit(store, chief)

        // The daemon's echo: its key in the `sidebar_doc` marker, as session.events sends it.
        store.receive(batch: Data("""
        {"changes": [{"kind": "state_upsert", "resource": "sidebar_doc", "id": "doc",
                      "value": {"revision": "2", "previous_revision": "1", "idempotency_key": "\(try #require(store.lastIntentKey))"}},
                     {"kind": "state_upsert", "resource": "sidebar_item", "id": "itm_chief",
                      "value": {"id": "itm_chief", "section": "sec_top", "order": "c", "body": {"type": "builtin", "id": "chief"}}}]}
        """.utf8))
        #expect(!store.isPending(chief.id), "the echoed Chief still counts as pending")
        #expect(Self.offersLabel(bridge, chief.id), "the echoed Chief's menu still leaves its label edit out")
    }

    /// A confirmed Chief with its label hidden, removed and added again (label shown) before either echo: the drawn
    /// Chief is the new add's, and its edit waits for that add's echo, not for the old Chief's record.
    @Test func aChiefRemovedAndAddedAgainIsTheNewAddsUntilItsEcho() async throws {
        let (services, store, end) = try await Self.pending(document: Self.document(chief: Self.hiddenLabelChief))
        defer { end() }
        let bridge = try Self.bridge(services)
        try store.sendChecked(ops: [["op": "item.remove", "id": "itm_chief"]], title: "Remove", undoable: false)
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"], "shows_label": true] as [String: Any],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        let chief = try #require(Self.drawn(store).first { $0.ref == .builtIn(.chief) }, "the Chief added again is not drawn")
        #expect(chief.showsLabel, "the Chief added again draws the removed Chief's hidden label")
        #expect(store.isPending(chief.id) && !Self.offersLabel(bridge, chief.id), "the Chief added again offers a label edit before its echo")
        try Self.expectNoLabelEdit(store, chief)
    }

    /// No top section yet: the add makes one with the Chief in it (or an undo puts both back, the label hidden), and the
    /// Chief draws there, as the change has it, before the echo, not in a machine list that does not exist.
    @Test(arguments: [false, true])
    func aChiefWhoseChangeMakesItsSectionDrawsInIt(undo: Bool) async throws {
        let (_, store, end) = try await Self.pending(document: Data(#"{"revision": "1", "sections": [], "items": []}"#.utf8))
        defer { end() }
        let empty = SidebarLayoutDocument(sections: [])
        let add = try #require(empty.addToTopOp(.builtIn(.chief), newItem: SidebarLayoutDocument.chiefItemID))
        let ops = undo ? [["op": "section.put", "section": ["id": "sec_new", "kind": ["type": "custom"], "region": "top", "scroll": "fixed", "order": "a"]],
                          ["op": "item.put", "item": ["id": "itm_chief", "section": "sec_new", "order": "a", "shows_label": false,
                                                      "body": ["type": "builtin", "id": "chief"]] as [String: Any]]]
            : try store.docOps(for: [add], layout: empty)
        try #require(undo || ops.contains { $0["op"] as? String == "section.add" }, "Add to Top with no top section made none: \(ops)")
        try store.sendChecked(ops: ops, title: "Add", undoable: false)
        let section = store.projection(live: [])?.layout.sections.first { $0.items.contains { $0.ref == .builtIn(.chief) } }
        #expect(section?.region == .top, "the Chief put back with its section draws in \(String(describing: section?.region))")
        #expect(section?.items.first?.showsLabel == !undo, "the Chief does not draw its change's label")
    }

    /// The Chief alone in This Mac's Work group, dragged out: the remove took the emptied group too, so its undo puts
    /// back both. Before the echo the Chief draws in the group the undo put back, not nowhere.
    @Test func anUndoThatPutsBackTheChiefsGroupDrawsTheChiefInIt() async throws {
        let (_, store, end) = try await Self.pending(document: Data(#"""
        {"revision": "1", "sections": [{"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}], "items": []}
        """#.utf8))
        defer { end() }
        try store.sendChecked(ops: [["op": "item.put", "item": ["id": "g_work", "section": "sec_m_s1", "order": "a",
                                                                 "body": ["type": "group", "name": "Work", "collapsed": false]] as [String: Any]],
                                    ["op": "item.put", "item": ["id": "itm_chief", "section": "sec_m_s1", "parent": "g_work", "order": "a",
                                                                 "body": ["type": "builtin", "id": "chief"]] as [String: Any]]],
                              title: "Undo Remove", undoable: false)
        try #require(store.placesItem(with: .builtIn(.chief)), "the undo placed no Chief")
        let listed = store.projection(live: [])?.machines["s1"]?.contains { node in
            if case let .group(group) = node { group.id == "g_work" && group.listed.contains { $0.item.id == "itm_chief" } } else { false }
        }
        #expect(listed == true, "the Chief put back with its group draws nowhere before the echo")
    }

    /// The daemon answered the add, then a reload (a reconnect) holds it before its echo: the load settles it, and the
    /// Chief is the document's again, its label edit offered.
    @Test func aReloadThatHoldsTheAnsweredAddSettlesIt() async throws {
        let remote = AnsweringRemote(document: Self.document())
        let (services, store, end) = try await Self.pending(remote: remote)
        defer { end() }
        let bridge = try Self.bridge(services)
        try store.sendChecked(ops: Self.addChief, title: "Add", undoable: false)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.answered > 0 }
        try #require(remote.answered == 1 && store.isPending(SidebarLayoutDocument.chiefItemID), "the add was not answered, or not pending")
        remote.document = Self.document(chief: Self.hiddenLabelChief)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { !store.isPending(SidebarLayoutDocument.chiefItemID) }
        #expect(!store.isPending(SidebarLayoutDocument.chiefItemID), "the reload that holds the answered add left the Chief pending")
        #expect(Self.drawn(store).first { $0.ref == .builtIn(.chief) }?.showsLabel == false, "the Chief does not draw the document's record")
        #expect(Self.offersLabel(bridge, SidebarLayoutDocument.chiefItemID), "the settled Chief's menu leaves its label edit out")
    }

    /// An undo puts the Chief back (`item.put`, as it was) and the daemon answers it; its echo is lost, and the reload
    /// after it holds the Chief as the undo put it. The mirror replays the put over the same record without dropping
    /// it, so the reload settles it by revision: a document at the answer's revision or later holds the change.
    @Test func aReloadAtTheAnsweredRevisionSettlesAnUndoThatPutTheChiefBack() async throws {
        let remote = AnsweringRemote(document: Self.document())
        let (services, store, end) = try await Self.pending(remote: remote)
        defer { end() }
        let bridge = try Self.bridge(services)
        try store.sendChecked(ops: [["op": "item.put", "item": ["id": "itm_chief", "section": "sec_top", "order": "c", "shows_label": false,
                                                                 "body": ["type": "builtin", "id": "chief"]] as [String: Any]]],
                              title: "Undo Remove", undoable: false)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.answered > 0 }
        try #require(remote.answered == 1 && store.isPending(SidebarLayoutDocument.chiefItemID), "the put was not answered, or not pending")
        remote.document = Data(String(decoding: Self.document(chief: Self.hiddenLabelChief), as: UTF8.self)
            .replacingOccurrences(of: #""revision": "1""#, with: #""revision": "2""#).utf8)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { !store.isPending(SidebarLayoutDocument.chiefItemID) }
        #expect(!store.isPending(SidebarLayoutDocument.chiefItemID), "the reload at the answered revision left the put Chief pending")
        #expect(Self.offersLabel(bridge, SidebarLayoutDocument.chiefItemID), "the settled Chief's menu leaves its label edit out")
    }

    /// The daemon answered a remove of the confirmed Chief and an add again (label shown), then a reload older than
    /// both: the mirror replays them, so the Chief stays the new add's, pending until its echo.
    @Test func aReloadOlderThanAnsweredChangesKeepsThemPending() async throws {
        let remote = AnsweringRemote(document: Self.document(chief: Self.hiddenLabelChief))
        let (services, store, end) = try await Self.pending(remote: remote)
        defer { end() }
        let bridge = try Self.bridge(services)
        try store.sendChecked(ops: [["op": "item.remove", "id": "itm_chief"]], title: "Remove", undoable: false)
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"], "shows_label": true] as [String: Any],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.answered == 2 }
        try #require(remote.answered == 2, "the daemon did not answer both changes")
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.gets > 1 }
        await RapidWorkspaceCreateTests.wait(within: .milliseconds(300)) { !store.isPending(SidebarLayoutDocument.chiefItemID) }
        #expect(store.isPending(SidebarLayoutDocument.chiefItemID), "the reload settled an add it does not hold")
        #expect(Self.drawn(store).first { $0.ref == .builtIn(.chief) }?.showsLabel == true, "the Chief draws the removed Chief's hidden label")
        #expect(!Self.offersLabel(bridge, SidebarLayoutDocument.chiefItemID), "the menu offers a label edit before the add's echo")
    }

    static func expectNoLabelEdit(_ store: SidebarDocStore, _ chief: LayoutItem) throws {
        let layout = try #require(store.projection(live: [])?.layout)
        #expect(throws: SidebarDocStore.LayoutOpGap.self, "an edit of the pending Chief was planned (sent before its add's echo)") {
            try store.docOps(for: [.itemUpdate(chief.id, showsLabel: !chief.showsLabel)], layout: layout)
        }
    }

    static func bridge(_ services: AppServices) throws -> SidebarBridge {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"chief","workspace_key":"chief-home"}"#.utf8))
        return SidebarBridge(services: services, state: WindowState(record: record))
    }

    /// Whether item `id`'s right-click menu offers Show/Hide Label.
    static func offersLabel(_ bridge: SidebarBridge, _ id: LayoutItemID) -> Bool {
        bridge.layoutItemMenu(id)?.items.contains { ($0.representedObject as? ActionMenuPayload)?.id == "sidebar.item.toggleLabel" } == true
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

    /// A confirmed Chief (label hidden) removed, then added again (label shown) before the remove is refused: the
    /// mirror puts the confirmed Chief back and drops the add it replays over it. The add settles with it: the Chief
    /// draws as confirmed, its label edit offered again.
    @Test func aRefusedRemoveSettlesTheAddItDropped() async throws {
        let (_, store, end) = try await Self.pending(document: Self.document(chief: Self.hiddenLabelChief), refusingRemoves: true)
        defer { end() }
        try store.sendChecked(ops: [["op": "item.remove", "id": "itm_chief"]], title: "Remove", undoable: false)
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"], "shows_label": true] as [String: Any],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        try #require(store.isPending(SidebarLayoutDocument.chiefItemID), "the Chief added again is not pending")
        let restored = { (Self.drawn(store).first { $0.ref == .builtIn(.chief) }?.showsLabel) == false }
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { restored() && !store.isPending(SidebarLayoutDocument.chiefItemID) }
        #expect(restored(), "the Chief draws the dropped add's label, not the confirmed record's")
        #expect(!store.isPending(SidebarLayoutDocument.chiefItemID), "the add the refusal dropped still counts as pending")
    }

    /// The same, when the remove is never answered and the reload that settles it comes after the add: the load
    /// holds the confirmed Chief, the remove it answers is put back, and the add the mirror drops then settles too.
    @Test func aReloadThatSettlesAnUnansweredRemoveSettlesTheAddItDropped() async throws {
        let remote = HeldReload(document: Self.document(chief: Self.hiddenLabelChief))
        let (_, store, end) = try await Self.pending(remote: remote)
        defer { end() }
        try store.sendChecked(ops: [["op": "item.remove", "id": "itm_chief"]], title: "Remove", undoable: false)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.held != nil }
        try #require(remote.held != nil, "the unanswered remove asked for no reload")
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"], "shows_label": true] as [String: Any],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        try #require(store.isPending(SidebarLayoutDocument.chiefItemID), "the Chief added again is not pending")
        remote.release()
        let restored = { (Self.drawn(store).first { $0.ref == .builtIn(.chief) }?.showsLabel) == false }
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { restored() && !store.isPending(SidebarLayoutDocument.chiefItemID) }
        #expect(restored(), "the Chief draws the dropped add's label, not the loaded record's")
        #expect(!store.isPending(SidebarLayoutDocument.chiefItemID), "the add the reload's refusal dropped still counts as pending")
    }

    /// A daemon that never answers a change (a remove times out at once, so the store asks for a reload), and holds
    /// every load after the first until the test releases it.
    @MainActor final class HeldReload: SidebarDocRemote {
        let document: Data
        var loads = 0
        var held: CheckedContinuation<Void, Never>?
        init(document: Data) { self.document = document }
        var isAvailable: Bool { true }
        func get() async throws -> Data {
            loads += 1
            if loads > 1 { await withCheckedContinuation { held = $0 } }
            return document
        }
        func release() {
            held?.resume()
            held = nil
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try await unanswered() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            if String(decoding: ops, as: UTF8.self).contains("remove") { throw SidebarDocUnsettled() }
            return try await unanswered()
        }
        private func unanswered() async throws -> SidebarDocReply {
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }

    /// A daemon that answers every change (with an inverse) and echoes none; its document is the test's.
    @MainActor final class AnsweringRemote: SidebarDocRemote {
        var document: Data
        var answered = 0, gets = 0
        init(document: Data) { self.document = document }
        var isAvailable: Bool { true }
        func get() async throws -> Data {
            gets += 1
            return document
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { answer() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { answer() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { answer() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { answer() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { answer() }
        private func answer() -> SidebarDocReply {
            answered += 1
            return SidebarDocReply(revision: 2, inverse: Data(#"[{"op": "item.remove", "id": "itm_chief"}]"#.utf8))
        }
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
