@testable import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// Task p09-observability-005: the app's launch path (`TraceBlackBoxFileSteps.startApp`, what AppServices
/// calls) attaches the heap ring at once and does its file work only on the `.files` lane: adoption and
/// cleanup posted at once, the spare only after ``TraceBlackBox/spareDelay``.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TraceBlackBoxFileStepsTests {
    /// The launch path on the main thread: no blocking site there, no file until the posted steps run, then
    /// the black-box file; the spare only once the clock passes the delay.
    @MainActor @Test func startAppPostsTheFileStepsAndMakesTheSpareAfterTheDelay() async throws {
        #if DEBUG
        let home = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lanes = HeldFiles()
        let clock = ManualClock()
        let runtime = TraceRuntime(role: .app)
        var posts = lanes.posts.makeAsyncIterator()
        let table = BlockingViolationTable(mode: .record)
        let steps = BlockingViolationTable.$scoped.withValue(table) {
            TraceBlackBoxFileSteps.startApp(bundleID: "test.trace.blackbox", work: lanes, runtime: runtime, clock: clock,
                                            home: URL(filePath: home))
        }
        await table.flush()
        let blackBox = steps.blackBox

        #expect(table.sites.isEmpty, "the launch path blocked on main: \(table.sites)")
        #expect(access(blackBox.directory, F_OK) != 0)
        #expect(lanes.held == [.userVisible, .bestEffort])
        let adoptPost = await posts.next()
        let cleanupPost = await posts.next()
        #expect(adoptPost == .userVisible)
        #expect(cleanupPost == .bestEffort)
        #expect(runtime.ring === blackBox.ring)
        #expect(runtime.categories == .blackBox)
        #expect(!blackBox.ring.isFileBacked)

        try await lanes.runHeld()
        #expect(blackBox.ring.isFileBacked)
        #expect(access(blackBox.filePath, F_OK) == 0)

        let spare = blackBox.directory + "/" + TraceRingFile.spareName(role: .app)
        try await clock.waitForSleeper()
        clock.advance(by: TraceBlackBox.spareDelay - .seconds(1))
        #expect(lanes.held.isEmpty)
        clock.advance(by: .seconds(1))
        let sparePost = await posts.next()
        #expect(sparePost == .idle)
        #expect(access(spare, F_OK) != 0)
        try await lanes.runHeld()
        #expect(access(spare, F_OK) == 0)
        withExtendedLifetime(steps) {}
        #endif
    }

    /// A trace point after the launch path lands in the ring, before and after the posted adoption.
    @Test func recordsGoToTheRingOnTheHeapAndThenInTheFile() async throws {
        let home = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lanes = HeldFiles()
        let runtime = TraceRuntime(role: .app)
        let steps = TraceBlackBoxFileSteps.startApp(bundleID: "test.trace.blackbox", work: lanes, runtime: runtime,
                                                    clock: ManualClock(), home: URL(filePath: home))
        // Bit 5: `launch`, a black-box category.
        runtime.write(name: 1, categoryBit: 5, phase: .instant, arg0: 11)
        try await lanes.runHeld()
        runtime.write(name: 1, categoryBit: 5, phase: .instant, arg0: 12)
        #expect(TraceRingFile.records(atPath: steps.blackBox.filePath)?.map(\.arg0) == [11, 12])
    }

    private static func temporaryFolder() throws -> String {
        var template = Array((NSTemporaryDirectory() + "trace-blackbox-steps-XXXXXX").utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        return try String(cString: #require(made))
    }
}

/// A ``MayBlockRunner`` that holds each posted `.files` item until the test runs it on a real `.files` lane, so
/// a test sees what was posted at which priority and that nothing ran on the poster's thread.
private final class HeldFiles: MayBlockRunner {
    private let lanes = BackgroundWork(label: "test.trace.blackbox")
    // concurrency-allow: the posted items, appended by the poster (main or the deadline's task) and taken by the test (lock carve-out: a list, no I/O under it).
    private let items = Mutex<[(priority: MayBlockPriority, body: @Sendable () -> Void)]>([])
    /// The priority of each post, in post order (the test's one iterator).
    let posts: AsyncStream<MayBlockPriority>
    private let posted: AsyncStream<MayBlockPriority>.Continuation

    init() {
        (posts, posted) = AsyncStream.makeStream(of: MayBlockPriority.self)
    }

    /// The priorities of the items posted and not run yet, in post order.
    var held: [MayBlockPriority] { items.withLock { $0.map(\.priority) } }

    /// Runs every held item on the `.files` lane, in post order.
    func runHeld() async throws {
        let bodies = items.withLock { held in
            defer { held.removeAll() }
            return held.map(\.body)
        }
        try await lanes.runFiles(.userVisible) { for body in bodies { body() } }
    }

    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
    }

    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
    }

    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
    }

    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void) {
        items.withLock { $0.append((priority, body)) }
        posted.yield(priority)
    }
}
