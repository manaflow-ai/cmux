import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// Hidden cmux pages in Chromium (Settings, Diff, Files, History, Stats, chats) freeze after
/// `browser.freezeHiddenTabs` seconds hidden, as hidden browser tabs do (perf-lead.md F3). Before
/// this, a cmux page that showed once kept its renderer's timers, React effects and 1 Hz clocks
/// running while hidden: only browser tabs froze (BrowserHibernation), and only idle local chats
/// with a session were released, after the hibernation threshold.
@Suite(.serialized)
@MainActor
struct CmuxPageFreezingTests {
    /// A clock whose sleeps end only when cancelled: the test runs each pass by hand.
    private struct StalledClock: Clock {
        var now: ContinuousClock.Instant { .now }
        var minimumResolution: Duration { .nanoseconds(1) }

        func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
            // A stream nobody yields to: iterating it ends only when the task is cancelled.
            let (pending, continuation) = AsyncStream<Void>.makeStream()
            for await _ in pending {}
            withExtendedLifetime(continuation) {}
            try Task.checkCancellation()
        }
    }

    /// The time the policy reads, stepped by the test.
    private final class TestTime {
        var now = ContinuousClock.now
    }

    private let root: URL
    private let stage = PageTestWindow()
    private let time = TestTime()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-page-freezing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func policy() -> CmuxPageFreezing {
        let freezing = CmuxPageFreezing(clock: StalledClock())
        let time = time
        freezing.now = { time.now }
        return freezing
    }

    /// A started Chromium page that booted (its first message reached the host), in a pane that
    /// the test hides and shows.
    private func bootedPage(_ hosting: FakeChromiumHosting) async throws -> (PageWebView, FakeChromiumPage, NSView) {
        let pane = stage.show(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let descriptor = PageDescriptor(id: "test.cmux-page-freezing", resource: "cmux-page-freezing", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = StalledClock()
        pane.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        view.chromiumSession?.reachedHost = true
        return (view, page, pane)
    }

    private func pass(after seconds: Double, _ freezing: CmuxPageFreezing) {
        time.now += .milliseconds(Int64(seconds * 1000))
        freezing.replan()
    }

    @Test func aHiddenPageFreezesAfterTheGraceAndThawsWhenItShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let freezing = policy()
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = freezing
        let (view, page, pane) = try await bootedPage(hosting)
        #expect(freezing.waitingCount == 0) // it shows

        pane.isHidden = true
        #expect(freezing.waitingCount == 1)
        #expect(freezing.hasDeadline)
        pass(after: 29, freezing)
        #expect(page.freezes.isEmpty)
        pass(after: 2, freezing)
        #expect(page.freezes == [true])
        #expect(view.isChromiumFrozen)
        #expect(freezing.frozenCount == 1)

        pane.isHidden = false
        #expect(Array(page.lifecycle.suffix(2)) == ["thawed", "shown"])
        #expect(freezing.waitingCount == 0)
        view.close()
    }

    /// A page the host keeps feeding (a chat that streams while hidden) stays awake: each push
    /// restarts its grace, and a push into a frozen page thaws it first.
    @Test func aPushRestartsTheGrace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let freezing = policy()
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = freezing
        let (view, page, pane) = try await bootedPage(hosting)
        pane.isHidden = true

        pass(after: 20, freezing)
        view.evaluate("window.__cmuxPush = 1")
        pass(after: 20, freezing)
        #expect(page.freezes.isEmpty)
        pass(after: 11, freezing)
        #expect(page.freezes == [true])

        view.evaluate("window.__cmuxPush = 2")
        #expect(page.freezes == [true, false])
        #expect(freezing.waitingCount == 1)
        pane.isHidden = false
        view.close()
    }

    @Test func offNeverFreezes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let freezing = policy()
        var setting = BrowserHibernationSetting.fallback
        setting.freezeSeconds = nil
        freezing.update(setting: setting)
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = freezing
        let (view, page, pane) = try await bootedPage(hosting)
        pane.isHidden = true
        pass(after: 1_000, freezing)
        #expect(page.freezes.isEmpty)
        #expect(!freezing.hasDeadline)
        view.close()
    }

    /// A page that hid before its first message still boots (a chat's seeded prompt runs at start):
    /// it is not frozen, and its first message reports it again.
    @Test func aPageThatStillBootsIsNotFrozen() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let freezing = policy()
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = freezing
        let (view, page, pane) = try await bootedPage(hosting)
        view.chromiumSession?.reachedHost = false
        pane.isHidden = true
        pass(after: 31, freezing)
        #expect(page.freezes.isEmpty)
        #expect(freezing.waitingCount == 0)
        view.close()
    }

    /// A closed page leaves the policy.
    @Test func aClosedPageIsForgotten() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let freezing = policy()
        let hosting = FakeChromiumHosting()
        hosting.freezePolicy = freezing
        let (view, _, pane) = try await bootedPage(hosting)
        pane.isHidden = true
        #expect(freezing.waitingCount == 1)
        view.close()
        #expect(freezing.waitingCount == 0)
        #expect(!freezing.hasDeadline)
    }
}
