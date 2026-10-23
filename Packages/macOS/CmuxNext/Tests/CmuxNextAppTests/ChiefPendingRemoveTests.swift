import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A Chief just dragged in, before the daemon answers (#23933 review, Codex round 3): the sidebar draws it at once,
/// so its drag out, its Remove from Sidebar and the App Store card's Remove find it through the App's own action, as
/// they find a confirmed one. Else the action says "no such sidebar item" and the Chief stays.
@MainActor @Suite(.serialized)
struct ChiefPendingRemoveTests {
    /// The sidebar document: one top section, no Chief.
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_top", "kind": {"type": "custom"}, "region": "top"}],
     "items": []}
    """.utf8)

    /// `target`: the item's id (a drag out, Remove from Sidebar) or the built-in's name (the App Store card).
    @Test(arguments: ["itm_chief", "chief"])
    func aChiefAddedAndNotYetConfirmedComesOffThroughTheAction(target: String) async throws {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: Self.document))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        store.show(live: [])
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        defer { SidebarDocStore.current = previous }

        // The test daemon never answers: no batch confirms the add or the remove.
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"]],
                                     "to": ["section": "sec_top"]]], title: "Add", undoable: false)
        try #require(store.placesItem(with: .builtIn(.chief)), "the added Chief does not count as placed")
        let drawn = store.projection(live: [])?.layout.sections.flatMap(\.items).map(\.ref) ?? []
        #expect(drawn.contains(.builtIn(.chief)), "the sidebar does not draw the Chief added before the daemon answered")

        let ran = services.registry.perform("sidebar.item.removeEverywhere",
                                            invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: target), origin: .user))
        #expect(ran, "Remove from Sidebar did not run for the pending Chief (\(target))")
        #expect(!store.placesItem(with: .builtIn(.chief)), "the pending Chief stayed placed after its Remove (\(target))")
    }
}
