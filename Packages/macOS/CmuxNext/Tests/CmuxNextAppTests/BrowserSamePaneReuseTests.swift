import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// A page-requested new tab reuses an existing page in the opener's pane. Explicit Duplicate Tab
/// uses BrowserTabDuplicate and remains a separate path.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct BrowserSamePaneReuseTests {
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aPageRequestReusesItsPaneTabAndKeepsTheFragment() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let created = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit,
                                                                      in: pane.pane.handle, activate: true)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil }, report: {
                WindowStateReport.describe(services, surface: created.surface)
            })
            let model = try #require(services.daemon.store.tab(surface: created.surface))
            let controller = try #require(services.paneController(for: pane.pane))
            try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.id == model.id } })
            controller.select(TabID(model.id), source: .intent)
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == model.id })
            try await PinnedPageTests.until({ services.cache.existingBrowser(model.id) != nil })
            let page = try #require(services.cache.existingBrowser(model.id)?.tab)
            let before = Set(pane.pane.tabs.map(\.id))
            let target = try #require(URL(string: "https://EXAMPLE.com/#section"))

            services.cache.pageRequests.browserTab(page, didRequest: .openURL(target, .foregroundTab))

            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == model.id && page.state.url?.fragment == "section" })
            #expect(Set(pane.pane.tabs.map(\.id)) == before, "the page request opened a duplicate browser tab")
            #expect(page.state.url?.fragment == "section", "the reused tab did not navigate to the requested fragment")
        }
    }
}
