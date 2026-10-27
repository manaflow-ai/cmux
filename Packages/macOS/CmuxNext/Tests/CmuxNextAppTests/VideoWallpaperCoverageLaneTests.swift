import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextWakeups
import Dispatch
import Testing

/// A video wallpaper's coverage sample lists the windows above its window on the players' system lane, never on
/// the main thread, and keeps at most one list pending (plans/cmux-next/chrome-parity/p02-threads.md, task 059):
/// a window server that answers slowly never piles samples up on the lane, and an old answer never lands after a
/// newer one.
extension VideoWallpaperTests {
    /// Real lanes whose system items wait for ``release``, counting them.
    nonisolated final class GatedRunner: MayBlockRunner {
        let lanes = BackgroundWork(label: "test.coverage-lane")
        let release = DispatchSemaphore(value: 0)
        private let items = Mutex(0)
        private let started: AsyncStream<Void>
        private let startedIn: AsyncStream<Void>.Continuation

        init() { (started, startedIn) = AsyncStream.makeStream(of: Void.self) }

        /// How many items went to the system lane.
        var systemItems: Int { items.withLock { $0 } }

        /// Returns once the next system item is on the lane.
        func nextItem() async {
            for await _ in started { return }
        }

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            items.withLock { $0 += 1 }
            return try await lanes.runSystem(priority, shutdown: shutdown, site: site) { [self] in
                startedIn.yield()
                release.wait()
                return try body()
            }
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            lanes.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aCoverageSampleListsTheWindowsOnTheSystemLaneOneAtATime() async throws {
        let clip = try await Self.clip()
        let runner = GatedRunner()
        let players = BackdropVideoPlayers()
        players.lanes = runner
        let h = make(.file(path: clip.path), players: players)
        defer { h.close() }
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        #endif
        let sample: @MainActor () async -> Void = {
            h.video.sampleCoverage()
            let first = h.video.coverageSample
            #expect(first != nil, "a sample with lanes listed no windows")
            await runner.nextItem()
            // Deadlines that come while the list is pending sample nothing.
            h.video.sampleCoverage()
            h.video.sampleCoverage()
            #expect(h.video.coverageSample == first, "a deadline replaced the pending sample")
            runner.release.signal()
            await first?.value
        }
        #if DEBUG || CMUX_BLOCKING_CHECKS
        await BlockingViolationTable.$scoped.withValue(table) { await sample() }
        await table.flush()
        let onMain = table.sites.filter { $0.context == .main }.map(\.location)
        #expect(onMain.isEmpty, "the coverage sample listed windows on the main thread: \(onMain)")
        #else
        await sample()
        #endif
        #expect(runner.systemItems == 1, "\(runner.systemItems) window lists for one pending sample")
        #expect(h.video.coverageSample == nil, "the answered sample stays pending")
        // The answer came: the next deadline lists again.
        h.video.sampleCoverage()
        await runner.nextItem()
        #expect(runner.systemItems == 2)
        runner.release.signal()
        await h.video.coverageSample?.value
    }
}
