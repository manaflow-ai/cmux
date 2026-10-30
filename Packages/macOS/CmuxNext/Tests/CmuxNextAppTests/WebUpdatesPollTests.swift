import CmuxNextCompat
@testable import CmuxNextUpdater
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The web-updates check: under Energy Saver it waits four intervals; while no
/// cmux window shows it books nothing (an activation brings none in), and a window showing again
/// books one check, an interval after the last. The booked check is a `background` deadline on the
/// app's deadline scheduler: here a rig whose wakes the test fires.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct WebUpdatesPollTests {
    /// Counts the pointer reads, from the fetch closure's thread.
    private nonisolated final class ReadCount: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    /// Answers every pointer read 304 (unchanged) and counts the reads.
    @MainActor private final class Rig {
        let deadlines = MainDeadlineRig(framed: false)
        let root: URL
        let updater: WebUpdater
        let reads: AsyncStream<Void>
        let readCount = ReadCount()

        init(energy: EnergyPolicySource = EnergyPolicySource(), checkNode: VisibilityNode? = nil, checksHeld: Bool = false) throws {
            root = try WebUpdateStoreTests.scratch()
            let (reads, read) = AsyncStream.makeStream(of: Void.self)
            self.reads = reads
            let readCount = readCount
            let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
            updater = WebUpdater(
                store: store, app: .init(abi: 2, webBuiltAt: 1_700_000_000), keys: .keys(WebUpdatePointerTests.keys),
                energy: energy, deadlines: deadlines.deadlines, checkNode: checkNode, work: BackgroundWork(label: "test.web-updates-poll"),
                checksHeld: checksHeld,
                fetch: { request in
                    readCount.add()
                    read.yield()
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil))
                    return (Data(), response)
                },
                download: { _ in throw URLError(.cancelled) })
            updater.channel = .everyMerge
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The time left until the booked check's wake (nil: none is booked).
        var booked: Duration? { deadlines.deadlines.nextFire }

        /// Waits for the next pointer read.
        func nextRead() async {
            for await _ in reads { return }
        }

        /// Whether a pointer read starts within `limit` (wall clock): a bound on a wait that must
        /// find nothing, so it ends the stream's use in a test.
        func readStarts(within limit: Duration) async -> Bool {
            let reads = reads
            let read = await Deadline(limit, ledger: WakeupLedger()).value("WebUpdatesPollTests.read") { () async -> Bool in
                for await _ in reads { return true }
                return false
            }
            return read ?? false
        }

        /// Waits until a check is booked again (a check's end books the next one on main).
        func waitForBooking() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while booked == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(booked != nil, "the check booked no next one")
        }
    }

    @Test func theWebUpdatesCheckWaitsFourIntervalsUnderTheSaver() async throws {
        let rig = try Rig(energy: EnergyPolicySource(EnergyPolicy(saverReason: .battery)))
        await rig.updater.check()
        let booked = try #require(rig.booked)
        #expect(booked == .seconds(240), "the saver's check waits four minutes: \(booked)")
        rig.updater.noteShown(false)
    }

    @Test func theWebUpdatesCheckBooksNothingWhileNoWindowShowsAndOneOnShow() async throws {
        let rig = try Rig()
        rig.updater.noteShown(false)
        await rig.updater.check()
        await rig.nextRead()
        #expect(rig.booked == nil, "a check booked the next one while no window showed")
        #expect(rig.readCount.count == 1)

        // The show books one check at most an interval after the last; it reads once, and the
        // next read waits a whole interval.
        rig.updater.noteShown(true)
        let booked = try #require(rig.booked)
        #expect(booked > .zero && booked <= .seconds(60))
        rig.deadlines.advance(by: .seconds(60))
        rig.deadlines.fireAtNow()
        await rig.nextRead()
        try await rig.waitForBooking()
        #expect(rig.readCount.count == 2, "a show read the pointer more than once")
        let next = try #require(rig.booked)
        #expect(next == .seconds(60), "the next read is not a whole interval away: \(next)")
        rig.deadlines.advance(by: .seconds(59))
        rig.deadlines.fireAtNow()
        #expect(rig.booked != nil)
        #expect(rig.readCount.count == 2, "a read came inside the interval after the show's check")

        // A window going away drops the booked check.
        rig.updater.noteShown(false)
        #expect(rig.booked == nil)
    }

    /// Startup holds the network (Chrome's AfterStartupTaskUtils): no channel
    /// follow, show or activation reads the pointer or books a read before ``WebUpdater/startChecks()``,
    /// which reads it once at once and books the next an interval out.
    @Test func noPointerIsReadBeforeStartupCompletes() async throws {
        let rig = try Rig(checksHeld: true)
        rig.updater.follow(.everyMerge)
        rig.updater.noteShown(false)
        rig.updater.noteShown(true)
        rig.updater.noteActivation(stale: 0)
        rig.updater.noteBackground()
        rig.updater.noteActivation(stale: 0)
        #expect(rig.booked == nil, "a held updater booked a check")
        // test-deadline: a bound on a wait that must find nothing, not a settle
        #expect(await rig.readStarts(within: .milliseconds(300)) == false, "a held updater read the pointer")
        #expect(rig.readCount.count == 0)
        #expect(rig.updater.lastCheck == nil)

        rig.updater.startChecks()
        #expect(!rig.updater.checksHeld)
        #expect(rig.booked != nil, "the start booked no check")
        rig.deadlines.fireAndRun()
        await rig.nextRead()
        try await rig.waitForBooking()
        #expect(rig.readCount.count == 1)
        let next = try #require(rig.booked)
        #expect(next == .seconds(60), "the next read is not a whole interval away: \(next)")
        // A second start books nothing more.
        rig.updater.startChecks()
        #expect(rig.booked == next)
        #expect(rig.readCount.count == 1)
        rig.updater.noteShown(false)
    }

    /// cmux coming to the front while no window shows neither books a check (a recent last check)
    /// nor reads at once (a stale one).
    @Test func anActivationWhileNoWindowShowsBooksAndReadsNothing() async throws {
        let rig = try Rig()
        rig.updater.noteShown(false)
        await rig.updater.check()
        await rig.nextRead()
        #expect(rig.readCount.count == 1)

        rig.updater.noteActivation()
        #expect(rig.booked == nil, "a hidden activation booked a check")

        // The last check is now older than `stale`: a shown app would read at once.
        let stale = try #require(rig.updater.lastCheck).timeIntervalSinceNow.magnitude / 2
        rig.updater.noteActivation(stale: stale)
        // test-deadline: a bound on a wait that must find nothing, not a settle
        #expect(await rig.readStarts(within: .milliseconds(300)) == false, "a hidden activation read the pointer")
        #expect(rig.readCount.count == 1)
        #expect(rig.booked == nil)
    }

    /// The booked check aligns to the app's hidden wakes (whole seconds) while the app is hidden,
    /// and is only flexible while it shows (update checks are hidden-aligned).
    @Test func theBookedCheckAlignsToTheHiddenAppsWakes() async throws {
        let app = VisibilityNode(root: "app", own: .hidden)
        let rig = try Rig(checkNode: app)
        await rig.updater.check()
        #expect(rig.updater.nextCheck.plannedWake?.rule == .hidden, "a hidden app's check is not hidden-aligned")
        app.set(.visible)
        #expect(rig.updater.nextCheck.plannedWake?.rule == .flexible, "a shown app's check stayed hidden-aligned")
        rig.updater.noteShown(false)
    }
}
