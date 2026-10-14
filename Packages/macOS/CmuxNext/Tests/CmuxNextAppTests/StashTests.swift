import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// Stash (a native OneTab, cx-rws36) through the app against a same-tree
/// cmux-tui daemon: the tab menu's Stash actions close the right browser
/// tabs into one group the Stashed page lists, the page restores and deletes
/// through its model, and pasted OneTab text imports as groups.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StashTests {
    @Test func stashTabsToTheRightClosesThePagesRightOfTheTabIntoOneListedGroup() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (ids, urls) = try await Self.openPages(4, services, connection)
            let store = services.daemon.store
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: ids[1]), origin: .user)
            #expect(services.registry.perform("tab.stashToRight", invocation: invocation))

            let model = services.historyPage.stash.model
            try await PinnedPageTests.until({ model.groups.count == 1 }, report: { "groups: \(model.groups)" })
            #expect(model.groups[0].tabs.map(\.url) == Array(urls[2...]), "the tabs right of the target, in pane order")
            try await PinnedPageTests.until({ ids[2...].allSatisfy { id in Self.tab(id, store) == nil } })
            #expect(ids[..<2].allSatisfy { Self.tab($0, store) != nil }, "the target and the tab left of it stay open")
        }
    }

    /// A group of the first and last page draws them together in the strip, [p0, p3, p1, p2]:
    /// right of p1 is p2 alone. (Older daemons kept [p0, p1, p2, p3]; the daemon now gathers
    /// group members itself, and the stash still reads the strip.)
    @Test func stashTabsToTheRightFollowsTheStripNotTheDaemonOrder() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (ids, urls) = try await Self.openPages(4, services, connection)
            let store = services.daemon.store
            let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
            let controller = try #require(services.paneController(for: pane))
            let resources = try ids.map { try #require(Self.tab($0, store)?.resourceID) }
            _ = try await connection.state.createTabGroup(tabs: [resources[0], resources[3]], name: nil, color: nil)
            try await PinnedPageTests.until({
                controller.orderedIDs.map(\.rawValue).filter(ids.contains) == [ids[0], ids[3], ids[1], ids[2]]
            }, report: { "strip: \(controller.orderedIDs)" })

            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: ids[1]), origin: .user)
            #expect(services.registry.perform("tab.stashToRight", invocation: invocation))
            let model = services.historyPage.stash.model
            try await PinnedPageTests.until({ model.groups.count == 1 }, report: { "groups: \(model.groups)" })
            #expect(model.groups[0].tabs.map(\.url) == [urls[2]], "only the page right of it in the strip")
            try await PinnedPageTests.until({ Self.tab(ids[2], store) == nil })
            #expect(Self.tab(ids[3], store) != nil, "the grouped page left of it in the strip stays open")
        }
    }

    @Test func thePageRestoresAndDeletesTabsAndGroups() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (ids, urls) = try await Self.openPages(3, services, connection)
            let store = services.daemon.store
            let first = ActionInvocation(target: ActionTargetRef(kind: .tab, id: ids[0]), origin: .user)
            #expect(services.registry.perform("tab.stashOthers", invocation: first))
            let model = services.historyPage.stash.model
            try await PinnedPageTests.until({ model.groups.first?.tabs.count == 2 }, report: { "groups: \(model.groups)" })
            #expect(model.groups[0].tabs.map(\.url) == Array(urls[1...]))

            // A row's ×: that tab goes for good.
            await model.delete(model.groups[0], tab: model.groups[0].tabs[0])
            #expect(model.groups.count == 1)
            #expect(model.groups[0].tabs.map(\.url) == [urls[2]])

            // A row's click: that tab comes back, the emptied group goes.
            await model.restore(model.groups[0], tab: model.groups[0].tabs[0])
            #expect(model.groups.isEmpty)
            try await PinnedPageTests.until({ Self.tab(url: urls[2], store) != nil }, report: { "no tab at \(urls[2])" })
            #expect(Self.tab(url: urls[1], store) == nil, "the deleted tab never came back")

            // Restore in New Workspace: every tab, in a workspace of its own.
            #expect(services.registry.perform("tab.stash", invocation: first))
            try await PinnedPageTests.until({ model.groups.count == 1 })
            let workspaces = Set(store.workspaces.map(\.id))
            await model.restoreInNewWorkspace(model.groups[0])
            #expect(model.groups.isEmpty)
            try await PinnedPageTests.until({
                store.workspaces.contains { !workspaces.contains($0.id) && Self.urls(of: $0).contains(urls[0]) }
            }, report: { "no new workspace with \(urls[0])" })

            // Delete Group.
            let again = Self.tab(url: urls[2], store).map { ActionInvocation(target: ActionTargetRef(kind: .tab, id: $0.id), origin: .user) }
            #expect(services.registry.perform("tab.stash", invocation: try #require(again)))
            try await PinnedPageTests.until({ model.groups.count == 1 })
            await model.delete(model.groups[0])
            #expect(model.groups.isEmpty)
        }
    }

    @Test func pastedOneTabTextImportsOneGroupPerBlankLineSeparatedBlock() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let model = services.historyPage.stash.model
            let draft = StashImportDraft()
            draft.open()
            draft.text = """
            https://a.example/one | One
            https://a.example/two | Two | with a bar

            https://b.example/ | B
            https://e.example/ |\u{20}
            not a page
            """
            await model.importPasted(draft)
            #expect(!draft.isOpen, "the paste box closes once the import went through")
            let groups = model.groups.map { $0.tabs.map(\.url) }
            #expect(Set(groups) == [
                ["https://a.example/one", "https://a.example/two"], ["https://b.example/", "https://e.example/"],
            ], "a `url | ` line is that page with no title")
            let a = try #require(model.groups.first { $0.tabs.first?.url == "https://a.example/one" })
            #expect(a.tabs.map(\.title) == ["One", "Two | with a bar"])

            // An imported page reopens in the app's browser engine.
            let b = try #require(model.groups.first { $0.tabs.first?.url == "https://b.example/" })
            #expect(b.tabs.map(\.title) == ["B", nil])
            await model.restore(b)
            let store = services.daemon.store
            try await PinnedPageTests.until({ Self.tab(url: "https://b.example/", store) != nil })
            guard case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) else {
                Issue.record("no browser engine resolves")
                return
            }
            #expect(Self.tab(url: "https://b.example/", store)?.browserEngine == choice.engine.rawValue)
        }
    }

    /// Opens `count` WebKit pages in the first pane and waits until its strip lists them.
    private static func openPages(_ count: Int, _ services: AppServices, _ connection: DaemonConnection) async throws -> ([String], [String]) {
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let urls = (0..<count).map { "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/\($0)" }
        var surfaces: [SurfaceID] = []
        for url in urls {
            surfaces.append(try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.handle, activate: false).surface)
        }
        let store = services.daemon.store
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0)?.resourceID != nil } })
        let ids = try surfaces.map { try #require(store.tab(surface: $0)).id }
        let controller = try #require(services.paneController(for: pane))
        try await PinnedPageTests.until({ Set(ids).isSubset(of: controller.orderedIDs.map(\.rawValue)) })
        return (ids, urls)
    }

    private static func tab(_ id: String, _ store: DaemonStore) -> TabModel? {
        store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.id == id }
    }

    private static func tab(url: String, _ store: DaemonStore) -> TabModel? {
        store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.url == url }
    }

    private static func urls(of workspace: WorkspaceModel) -> [String] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(\.url)
    }
}
