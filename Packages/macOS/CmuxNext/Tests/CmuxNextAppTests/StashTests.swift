import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// Stash (a native OneTab, cx-rws36) through the app against a same-tree cmux-tui daemon: the
/// Stashed page's model follows stash changes another client makes, restores and deletes
/// through the daemon, and pasted OneTab text imports as groups. The Stash actions that close
/// tabs into stashes land in a later slice of #20706.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StashTests {
    /// A stash stored or deleted outside the page (as the CLI, MCP or another window does, here
    /// straight on the connection) shows without a reload: the daemon's `session.events` stash
    /// change makes the model list again.
    @Test func theModelFollowsTheDaemonsStashChanges() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let model = services.historyPage.stash.model
            try await PinnedPageTests.until({ services.daemon.store.session.stashChanges > 0 })
            let url = "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/"
            _ = try await connection.state.importOneTab([.init(name: nil, pages: [.init(url: url, title: "Other client")])], engine: "webkit")
            try await PinnedPageTests.until({ model.groups.contains { $0.tabs.map(\.url) == [url] } },
                                            report: { "groups: \(model.groups)" })

            let group = try #require(model.groups.first { $0.tabs.map(\.url) == [url] })
            try await connection.state.deleteStash(group.id)
            try await PinnedPageTests.until({ !model.groups.contains { $0.id == group.id } }, report: { "groups: \(model.groups)" })
        }
    }

    @Test func thePageRestoresAndDeletesTabsAndGroups() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let model = services.historyPage.stash.model
            let store = services.daemon.store
            let urls = (0..<3).map { "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/\($0)" }
            let draft = StashImportDraft()
            draft.text = urls.map { "\($0) | Page" }.joined(separator: "\n")
            await model.importPasted(draft)
            let imported = try #require(model.groups.first { $0.tabs.map(\.url) == urls }, "groups: \(model.groups)")

            // A row's ×: that tab goes for good.
            await model.delete(imported, tab: imported.tabs[0])
            let afterDelete = try #require(model.groups.first { $0.id == imported.id })
            #expect(afterDelete.tabs.map(\.url) == Array(urls[1...]))

            // A row's click: that tab comes back; the group keeps the rest.
            await model.restore(afterDelete, tab: afterDelete.tabs[0])
            try await PinnedPageTests.until({ Self.tab(url: urls[1], store) != nil }, report: { "no tab at \(urls[1])" })
            #expect(model.groups.first { $0.id == imported.id }?.tabs.map(\.url) == [urls[2]])
            #expect(Self.tab(url: urls[0], store) == nil, "the deleted tab never came back")

            // Restore in New Workspace: every tab left, in a workspace of its own; the emptied group goes.
            let workspaces = Set(store.workspaces.map(\.id))
            await model.restoreInNewWorkspace(try #require(model.groups.first { $0.id == imported.id }))
            #expect(!model.groups.contains { $0.id == imported.id })
            try await PinnedPageTests.until({
                store.workspaces.contains { !workspaces.contains($0.id) && Self.urls(of: $0).contains(urls[2]) }
            }, report: { "no new workspace with \(urls[2])" })

            // Delete Group.
            let other = StashImportDraft()
            other.text = "https://stash-delete.example/ | Gone"
            await model.importPasted(other)
            let doomed = try #require(model.groups.first { $0.tabs.first?.url == "https://stash-delete.example/" })
            await model.delete(doomed)
            #expect(!model.groups.contains { $0.id == doomed.id })
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

    private static func tab(url: String, _ store: DaemonStore) -> TabModel? {
        store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.url == url }
    }

    private static func urls(of workspace: WorkspaceModel) -> [String] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(\.url)
    }
}
