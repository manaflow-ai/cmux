import AppKit
import Foundation
import Testing
@testable import CmuxNextApps

/// The App Store as tabs: one view per tab, no window, separate state per tab over one apps client.
@MainActor
struct AppStorePagesTests {
    private func pages() async -> (AppStorePages, AppsClient, FakeAppsTransport) {
        let (client, transport) = await TestClient.make()
        let pages = AppStorePages { AppStoreModel(client: client) }
        return (pages, client, transport)
    }

    @Test func eachTabGetsOneViewAndNoWindowOpens() async {
        let (pages, _, _) = await pages()
        let windows = NSApp?.windows.count ?? 0
        let first = pages.makeView(for: "local-page:app-store:a")
        #expect(first.window == nil)
        let model = pages.model(for: "local-page:app-store:a")
        _ = pages.makeView(for: "local-page:app-store:a")
        #expect(pages.model(for: "local-page:app-store:a") === model) // one model per tab
        #expect((NSApp?.windows.count ?? 0) == windows)
        #expect(pages.model(for: "local-page:app-store:a") != nil)
    }

    @Test func tabsKeepTheirOwnSelectionOverOneClient() async {
        let (pages, client, _) = await pages()
        _ = pages.makeView(for: "a")
        _ = pages.makeView(for: "b")
        pages.present("a", appID: "cmux/github-prs", installed: false)
        pages.present("b", appID: nil, installed: true)
        let a = pages.model(for: "a"), b = pages.model(for: "b")
        #expect(a !== b)
        #expect(a?.client === client && b?.client === client)
        #expect(a?.tab == .discover)
        #expect(b?.tab == .installed)
        pages.tabClosed("a")
        #expect(pages.model(for: "a") == nil)
        #expect(pages.model(for: "b") != nil)
    }

    /// Closing the tab inside a Remove's undo window still removes the app: the user asked for a
    /// remove, and a closed tab has no Undo left to show.
    @Test func closingTheTabCommitsAPendingRemove() async throws {
        let (pages, client, _) = await pages()
        _ = pages.makeView(for: "a")
        let model = try #require(pages.model(for: "a"))
        try await model.install("cmux/github-prs")
        await model.requestRemove("cmux/github-prs")
        #expect(client.app("cmux/github-prs")?.installed == true)
        pages.tabClosed("a")
        #expect(await eventually { await MainActor.run { client.app("cmux/github-prs")?.installed == false } })
    }

    @Test func showSelectsAListing() async {
        let (pages, _, _) = await pages()
        _ = pages.makeView(for: "a")
        pages.present("a", appID: "cmux/agent-status", installed: false)
        #expect(pages.model(for: "a")?.selectedListing?.id == "cmux/agent-status")
    }
}
