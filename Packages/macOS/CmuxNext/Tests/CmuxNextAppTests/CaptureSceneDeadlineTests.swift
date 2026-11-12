#if DEBUG
import CmuxNextControl
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// A capture scene ends by its own deadline when what it waits for never comes (review of #41359:
/// `page?.waitUntilLoaded()` had no timeout or cancellation, so a stalled page hung the capture past
/// the scene deadlines). Each test bounds its own wait, so a hang is a clean failure, not a stuck run.
@MainActor @Suite(.serialized) struct CaptureSceneDeadlineTests {
    /// What a bounded wait saw: whether it returned, and what it answered.
    private final class Outcome {
        var returned = false
        var loaded: Bool?
        var visible: Double??
    }

    /// A page web view that never loads its document: it serves only its own scratch `index.html`
    /// (no built bundle), and is never told to load it. The caller removes `root`.
    private static func neverLoadingPage(_ id: String) throws -> (page: PageWebView, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "never-loads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Never loads</title>".utf8).write(to: root.appending(path: "index.html"))
        let descriptor = PageDescriptor(id: id, resource: "never-loads", namespaces: [])
        let host = PageWebView.hostConfiguration(handler: PageSchemeHandler(page: descriptor, root: root, devServer: nil),
                                                 documentAttributes: [:], options: .standard)
        let page = PageWebView(descriptor: descriptor, configuration: host.configuration, inputReadiness: host.inputReadiness,
                               routes: [], route: nil, options: .standard, surface: nil, dynamicResources: nil,
                               pooled: false, load: false, chromium: nil)
        return (page, root)
    }

    /// Lets main-actor tasks run until `condition` holds, for at most about two seconds.
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The permission-feed-peer row: the pinned Needs you page never loads. The scene's load wait
    /// (``PageWebView/waitUntilLoaded(within:)``, bounded by the row's deadline) answers by that
    /// deadline that the page did not load.
    @Test func aPageThatNeverLoadsAnswersByTheDeadline() async throws {
        let (page, root) = try Self.neverLoadingPage("test.capture-never-loads")
        defer { page.close(); try? FileManager.default.removeItem(at: root) }
        let outcome = Outcome()
        let started = ContinuousClock.now
        let wait = Task { @MainActor in
            outcome.loaded = await page.waitUntilLoaded(within: .milliseconds(100))
            outcome.returned = true
        }
        await until { outcome.returned }
        let took = ContinuousClock.now - started
        wait.cancel()
        #expect(outcome.returned, "the load wait hung past its 100 ms deadline")
        #expect(outcome.loaded == false, "the page did not load within the deadline")
        #expect(took < .milliseconds(1_100), "it answered by the deadline plus a margin")
    }

    /// A cancelled load wait returns at once: the deadline that won leaves no waiter parked on the page.
    @Test func aCancelledPageLoadWaitReturns() async throws {
        let (page, root) = try Self.neverLoadingPage("test.capture-cancelled-load")
        defer { page.close(); try? FileManager.default.removeItem(at: root) }
        let outcome = Outcome()
        let wait = Task { @MainActor in
            await page.waitUntilLoaded()
            outcome.returned = true
        }
        await Task.yield()
        wait.cancel()
        await until { outcome.returned }
        #expect(outcome.returned, "a cancelled waitUntilLoaded stayed parked")
    }

    /// Every scene's frame wait (``BenchFrames/settled(until:start:window:deadline:watchCommits:)``) ends
    /// at its deadline even when no display tick comes (a window that stopped drawing).
    @Test func aFrameWaitEndsAtItsDeadlineWithoutATick() async {
        let frames = BenchFrames() // never started: no display tick
        let outcome = Outcome()
        let wait = Task { @MainActor in
            outcome.visible = await frames.settled(until: { false }, start: .now, window: 0, deadline: 100)
            outcome.returned = true
        }
        await until { outcome.returned }
        wait.cancel()
        #expect(outcome.returned, "the frame wait hung past its 100 ms deadline")
        #expect(outcome.visible == .some(nil), "nothing held: nil at the deadline")
    }

    /// A cancelled frame wait returns at once, long before its deadline.
    @Test func aCancelledFrameWaitReturns() async {
        let frames = BenchFrames()
        let outcome = Outcome()
        let wait = Task { @MainActor in
            outcome.visible = await frames.settled(until: { false }, start: .now, window: 0, deadline: 60_000)
            outcome.returned = true
        }
        await Task.yield()
        wait.cancel()
        await until { outcome.returned }
        #expect(outcome.returned, "a cancelled frame wait stayed parked until its deadline")
    }
}
#endif
