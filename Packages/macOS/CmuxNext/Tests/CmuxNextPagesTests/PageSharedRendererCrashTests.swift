@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// cmux pages of one site share a Chromium renderer (p07-memory 049, PL-memory's
/// `cmux-page-scheme-process-per-site`), so one renderer end takes every page in it: Chromium reports
/// it to each page's browser (`OnRenderProcessTerminated`, one per browser), and each page reloads under
/// its own ``PageCrashReloads``, as each Chrome tab of a shared renderer shows its own sad tab.
@MainActor
struct PageSharedRendererCrashTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.shared-renderer", resource: "shared-renderer", processGroup: .agent, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-shared-renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// Three pages of one site, each in Chromium, all at `now`.
    private func openThree(_ hosting: FakeChromiumHosting, now: Date) async throws -> [PageWebView] {
        var views: [PageWebView] = []
        for _ in 0..<3 {
            let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: nil, chromium: hosting))
            view.chromiumClock = PageTestClock.never
            view.now = { now }
            await view.chromiumStart?.value
            try #require(view.chromiumSession != nil)
            views.append(view)
        }
        return views
    }

    @Test func aSharedRendererEndReloadsEveryPageInIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let views = try await openThree(hosting, now: Date(timeIntervalSince1970: 1_000))
        defer { views.forEach { $0.close() } }
        try #require(hosting.made.count == 3)
        var crashes: [(page: ObjectIdentifier, reloading: Bool)] = []
        for view in views { view.onCrash = { page, reloading in crashes.append((ObjectIdentifier(page), reloading)) } }

        // The renderer the three pages share ends: Chromium tells each page's browser.
        for page in hosting.made { page.onEvent?(.crashed) }

        #expect(hosting.made.map(\.reloads) == [1, 1, 1], "a page of the ended renderer stayed blank")
        #expect(Set(crashes.map { $0.page }) == Set(views.map { ObjectIdentifier($0) }))
        #expect(crashes.count == 3 && crashes.allSatisfy { $0.reloading })
    }

    /// Each end of the shared renderer is one crash of every page in it: a renderer that keeps
    /// crashing stops every page's reloads together after ``PageCrashReloads/limit``, and a page's
    /// Reload button starts only that page again.
    @Test func aRendererThatKeepsCrashingStopsEveryPagesReloads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let views = try await openThree(hosting, now: Date(timeIntervalSince1970: 1_000))
        defer { views.forEach { $0.close() } }
        for _ in 0...PageCrashReloads.limit {
            for page in hosting.made { page.onEvent?(.crashed) }
        }
        #expect(hosting.made.map(\.reloads) == Array(repeating: PageCrashReloads.limit, count: 3))

        views[0].reloadAfterCrashes()
        #expect(hosting.made.map(\.reloads) == [PageCrashReloads.limit + 1, PageCrashReloads.limit, PageCrashReloads.limit])
    }
}
