@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A browser tab the daemon closes on its own (`cmux tab close`, another client, a batch close)
/// lets its page go as the app's own close does. Before, only terminals were released when the
/// daemon tree dropped their tab: a Chromium page kept its browser and renderer until the app quit.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct DaemonClosedBrowserPageTests {
    @Test func aBrowserTabTheDaemonClosesReleasesItsPage() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
            var surfaces: [SurfaceID] = []
            for index in 0..<2 {
                let url = "https://daemon-close-\(UUID().uuidString.prefix(6).lowercased()).example/\(index)"
                surfaces.append(try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.handle, activate: false).surface)
            }
            try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0)?.resourceID != nil } })
            let tabs = try surfaces.map { try #require(store.tab(surface: $0)) }
            for tab in tabs { _ = services.cache.browser(for: tab) }
            // The tab left open lets its page go when the test ends, as a closed tab's does.
            defer { services.cache.release(tabs[0].id) }
            #expect(tabs.allSatisfy { services.cache.hasContent(for: $0.id) }, "each tab has its page")

            let closing = tabs[1]
            try await connection.closeTab(closing.surface)
            try await PinnedPageTests.until({ store.tab(surface: closing.surface) == nil })
            try await PinnedPageTests.until({ !services.cache.hasContent(for: closing.id) }, report: { "the closed tab's page stayed" })
            #expect(services.cache.hasContent(for: tabs[0].id), "the open tab keeps its page")
        }
    }
}
