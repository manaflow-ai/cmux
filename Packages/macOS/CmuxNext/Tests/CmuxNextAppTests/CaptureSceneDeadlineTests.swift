#if DEBUG
import CmuxNextControl
@testable import CmuxNextPages
import CmuxNextWakeupsTestSupport
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
    /// (``PageWebView/waitUntilLoaded(within:clock:)``, bounded by the row's deadline) is still waiting
    /// just before its deadline and answers "not loaded" once the deadline comes, on a manual clock.
    @Test func aPageThatNeverLoadsAnswersByTheDeadline() async throws {
        let (page, root) = try Self.neverLoadingPage("test.capture-never-loads")
        defer { page.close(); try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock()
        let deadline = Duration.seconds(6)
        let outcome = Outcome()
        let wait = Task { @MainActor in
            outcome.loaded = await page.waitUntilLoaded(within: deadline, clock: clock)
            outcome.returned = true
        }
        defer { wait.cancel() }
        try await clock.waitForSleeper()
        clock.advance(by: deadline - .milliseconds(1))
        await Task.yield()
        #expect(!outcome.returned, "the wait answered before its deadline")
        clock.advance(by: .milliseconds(1))
        await until { outcome.returned }
        #expect(outcome.returned, "the load wait hung past its deadline")
        #expect(outcome.loaded == false, "the deadline's answer: the page did not load")
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

    /// Review F1 of #41480: a cancel that lands while the wait registers, after it read
    /// `Task.isCancelled` and before it scheduled its deadline, still ends the wait at once. Its
    /// cancel no longer reschedules the deadline timer the registration then replaced.
    @Test func aCancelWhileTheFrameWaitRegistersReturns() async {
        // No deadline timer fires, not even a zero-delay one: only the cancel can end the wait.
        let frames = BenchFrames(clock: StoppedClock())
        frames.beforeSchedulingDeadline = { withUnsafeCurrentTask { $0?.cancel() } }
        let outcome = Outcome()
        let wait = Task { @MainActor in
            outcome.visible = await frames.settled(until: { false }, start: .now, window: 0, deadline: 60_000)
            outcome.returned = true
        }
        await until { outcome.returned }
        wait.cancel()
        #expect(outcome.returned, "a frame wait cancelled as it registered stayed parked until its deadline")
        #expect(outcome.visible == .some(nil), "nothing held: nil")
    }
}

/// A clock whose time never passes: a sleep on it, even a zero-delay one, ends only when cancelled.
private struct StoppedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
#endif
