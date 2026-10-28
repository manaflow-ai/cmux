@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Characterization of the per-page crash path that pages in a shared renderer rely on (p07-memory
/// 049). It models no renderer: each fake page gets its own `.crashed`, as Chromium sends
/// `OnRenderProcessTerminated` to each browser of an ended renderer. It passes without 049 and is not
/// evidence that a shared renderer's end reaches its pages; only a fork or fleet run that kills the
/// shared renderer shows that.
///
/// The decision it pins: the app cannot tell which page of a shared renderer made it crash, so every
/// page counts each end under its own ``PageCrashReloads``, and a renderer that keeps crashing stops
/// all of them together. Only the person's Reload starts one again, as each Chrome tab of a shared
/// renderer shows its own sad tab.
@MainActor
struct PageCrashReloadsPerPageTests {
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
            let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: nil, chromium: hosting, deadlines: .testing()))
            view.chromiumDeadlines = LifecycleDeadlineRig.never
            view.now = { now }
            await view.chromiumStart?.value
            try #require(view.chromiumSession != nil)
            views.append(view)
        }
        return views
    }

    @Test func eachPagesCrashReloadsThatPage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let views = try await openThree(hosting, now: Date(timeIntervalSince1970: 1_000))
        defer { views.forEach { $0.close() } }
        try #require(hosting.made.count == 3)
        var crashes: [(page: ObjectIdentifier, reloading: Bool)] = []
        for view in views { view.onCrash = { page, reloading in crashes.append((ObjectIdentifier(page), reloading)) } }

        // What Chromium sends when a renderer the three share ends: one termination per browser.
        for page in hosting.made { page.onEvent?(.crashed) }

        #expect(hosting.made.map(\.reloads) == [1, 1, 1], "a page of the ended renderer stayed blank")
        #expect(Set(crashes.map { $0.page }) == Set(views.map { ObjectIdentifier($0) }))
        #expect(crashes.count == 3 && crashes.allSatisfy { $0.reloading })
    }

    /// The suite's decision: a crash loop of pages that share a renderer stops every page's reloads
    /// together after ``PageCrashReloads/limit``, and a page's Reload button starts only that page again.
    @Test func pagesThatCrashTogetherStopReloadingTogether() async throws {
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
