import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// "Use Test Update Feed" (coordinator 2026-10-04): DEV and NIGHTLY only,
/// https (or a loopback http server), visible while active, gone after a
/// relaunch unless pinned.
@MainActor
@Suite struct UpdaterTestFeedTests {
    private func service(_ bundle: String, defaults: UserDefaults) -> UpdaterService {
        // The track comes from the bundle id (DEV) or the baked feed.
        let feed = switch bundle {
        case "com.cmuxterm.app.nightly": "https://files-next.cmux.com/nightly-next/appcast.xml"
        case "com.cmuxterm.app.rc": "https://files.cmux.com/rc/appcast.xml"
        default: "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"
        }
        return UpdaterService(identity: AppcastFixtures.identity(bundle: bundle, build: "100", feed: feed),
                       policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "cmux-next-test-feed-\(UUID().uuidString)")!
    }

    @Test func stableAndRCRefuseATestFeed() {
        let store = defaults()
        #expect(throws: (any Error).self) { try service("com.cmuxterm.app", defaults: store).useTestFeed("https://example.com/a.xml", pinned: false) }
        #expect(throws: (any Error).self) { try service("com.cmuxterm.app.rc", defaults: store).useTestFeed("https://example.com/a.xml", pinned: false) }
    }

    @Test func onlyHTTPSOrLoopbackHTTP() throws {
        let nightly = service("com.cmuxterm.app.nightly", defaults: defaults())
        #expect(throws: (any Error).self) { try nightly.useTestFeed("http://example.com/a.xml", pinned: false) }
        #expect(throws: (any Error).self) { try nightly.useTestFeed("file:///tmp/a.xml", pinned: false) }
        try nightly.useTestFeed("http://127.0.0.1:8080/appcast.xml", pinned: false)
        #expect(nightly.testFeedURL == "http://127.0.0.1:8080/appcast.xml")
    }

    @Test func anUnpinnedTestFeedEndsWithTheProcess() throws {
        let store = defaults()
        let first = service("com.cmuxterm.app.nightly", defaults: store)
        try first.useTestFeed("https://example.com/test/appcast.xml", pinned: false)
        #expect(first.testFeedURL == "https://example.com/test/appcast.xml")
        #expect(service("com.cmuxterm.app.nightly", defaults: store).testFeedURL == nil)
    }

    @Test func aPinnedTestFeedSurvivesARelaunchUntilCleared() throws {
        let store = defaults()
        try service("com.cmuxterm.app.nightly", defaults: store).useTestFeed("https://example.com/test/appcast.xml", pinned: true)
        let relaunched = service("com.cmuxterm.app.nightly", defaults: store)
        #expect(relaunched.testFeedURL == "https://example.com/test/appcast.xml")
        try relaunched.useTestFeed(nil, pinned: false)
        #expect(relaunched.testFeedURL == nil)
        #expect(service("com.cmuxterm.app.nightly", defaults: store).testFeedURL == nil)
    }

    @Test func statusShowsTheActiveTestFeed() throws {
        let nightly = service("com.cmuxterm.app.nightly", defaults: defaults())
        try nightly.useTestFeed("https://example.com/test/appcast.xml", pinned: false)
        #expect(nightly.status.testFeedURL == "https://example.com/test/appcast.xml")
    }
}
