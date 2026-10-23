import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A Chief just dragged in, before the daemon answers (#23933 review, Codex rounds 3 and 4): the sidebar draws it at
/// once, so its drag out, its Remove from Sidebar and the App Store card's Remove find it through the App's own
/// action, as they find a confirmed one; a second add is ignored (one Chief); and an edit of it waits for the echo
/// rather than draw from a stale record.
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
    static func pending() async throws -> (AppServices, SidebarDocStore, end: () -> Void) {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: document))
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

    /// An edit of the pending Chief (its label on a line) before the daemon answers the add: either it waits for the
    /// echo (nothing is sent), or the sidebar draws it. Never sent and drawn from the add's stale record.
    @Test func anEditOfThePendingChiefIsNeverDrawnStale() async throws {
        let (_, store, end) = try await Self.pending()
        defer { end() }
        try store.sendChecked(ops: Self.addChief, title: "Add", undoable: false)
        let before = try #require(Self.drawn(store).first { $0.ref == .builtIn(.chief) }, "the pending Chief is not drawn")
        let layout = try #require(store.projection(live: [])?.layout)
        guard let ops = try? store.docOps(for: [.itemUpdate(before.id, showsLabel: !before.showsLabel)], layout: layout) else { return }
        try store.sendChecked(ops: ops, title: "Label", undoable: false)
        let after = Self.drawn(store).first { $0.ref == .builtIn(.chief) }
        #expect(after?.showsLabel == !before.showsLabel, "the label edit was sent but the pending Chief draws its old label")
    }
}
