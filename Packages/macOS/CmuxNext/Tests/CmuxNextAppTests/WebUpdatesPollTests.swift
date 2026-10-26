@testable import CmuxNextUpdater
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The web-updates check (p14-energy-032): under Energy Saver it waits four intervals; while no
/// cmux window shows it books nothing, and a window showing again books one check, an interval
/// after the last.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct WebUpdatesPollTests {
    /// Answers every pointer read 304 (unchanged) and counts the reads.
    private final class Rig {
        let clock = ManualClock()
        let root: URL
        let updater: WebUpdater
        let reads: AsyncStream<Void>

        init(energy: EnergyPolicySource = EnergyPolicySource()) throws {
            root = try WebUpdateStoreTests.scratch()
            let (reads, read) = AsyncStream.makeStream(of: Void.self)
            self.reads = reads
            let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
            updater = WebUpdater(
                store: store, app: .init(abi: 2, webBuiltAt: 1_700_000_000), keys: WebUpdatePointerTests.keys,
                energy: energy, clock: clock,
                fetch: { request in
                    read.yield()
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil))
                    return (Data(), response)
                },
                download: { _ in throw URLError(.cancelled) })
            updater.channel = .everyMerge
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Waits for the next pointer read.
        func nextRead() async {
            for await _ in reads { return }
        }
    }

    @Test func theWebUpdatesCheckWaitsFourIntervalsUnderTheSaver() async throws {
        let rig = try Rig(energy: EnergyPolicySource(EnergyPolicy(saverReason: .battery)))
        await rig.updater.check()
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleepRequests.last?.deadline.offset == .seconds(240), "the saver's check waits four minutes")
        rig.updater.noteShown(false)
    }

    @Test func theWebUpdatesCheckBooksNothingWhileNoWindowShowsAndOneOnShow() async throws {
        let rig = try Rig()
        rig.updater.noteShown(false)
        await rig.updater.check()
        await rig.nextRead()
        await #expect(throws: ManualClock.NoSleeper.self, "a check booked the next one while no window showed") {
            // test-deadline: a bound on a wait that must find nothing, not a settle
            try await rig.clock.waitForSleeper(within: .milliseconds(300))
        }

        // The show books one check at most an interval after the last; it runs once.
        rig.updater.noteShown(true)
        try await rig.clock.waitForSleeper()
        let booked = try #require(rig.clock.sleepRequests.last?.deadline.offset)
        #expect(booked > .zero && booked <= .seconds(60))
        rig.clock.advance(by: .seconds(60))
        await rig.nextRead()
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleeperCount == 1, "a show booked more than one check")

        // A window going away drops the booked check.
        rig.updater.noteShown(false)
        #expect(rig.clock.sleeperCount == 0)
    }
}
