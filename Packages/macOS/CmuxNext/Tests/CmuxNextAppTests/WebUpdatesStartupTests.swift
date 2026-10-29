import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextUpdater
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// The app-level startup hold of web updates (Chrome's AfterStartupTaskUtils):
/// ``WebUpdates`` reads no channel pointer from the network before ``WebUpdates/startChecks()``,
/// whether startup completes after the launch read made the updater or before it.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct WebUpdatesStartupTests {
    static let work = BackgroundWork(label: "test.web-updates-startup")

    /// Counts the pointer reads, from the fetch closure's thread.
    private nonisolated final class ReadCount: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    /// A ``WebUpdates`` on its own overlay, whose transport answers every pointer
    /// read 304 (unchanged) and counts the reads, following `updates.web: every-merge`. Its checks
    /// are deadlines on a rig's scheduler whose wakes the test fires.
    @MainActor private final class Rig {
        let deadlines = MainDeadlineRig(framed: false)
        let root: URL
        let overlay = WebBundleOverlay(bases: [])
        let web: WebUpdates
        let launch: LaunchRead<WebUpdates.Launch?>
        let reads: AsyncStream<Void>
        let readCount = ReadCount()

        init() throws {
            root = try WebUpdateStoreTests.scratch()
            let (reads, read) = AsyncStream.makeStream(of: Void.self)
            self.reads = reads
            let readCount = readCount
            let transport = WebUpdates.Transport(
                fetch: { request in
                    readCount.add()
                    read.yield()
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil))
                    return (Data(), response)
                },
                download: { _ in throw URLError(.cancelled) })
            web = WebUpdates(overlay: overlay, transport: transport)
            let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
            let app = WebUpdater.App(abi: 2, webBuiltAt: 1_700_000_000)
            launch = LaunchRead<WebUpdates.Launch?>(on:WebUpdatesStartupTests.work, dropped: .some(nil)) {
                WebUpdates.Launch(app: app, store: store, kept: WebUpdater.readKept(store: store, app: app))
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Starts web updates with the launch read, as `AppDelegate` does.
        func prepare() {
            var settings = UpdatesSettings()
            settings.web = .everyMerge
            web.prepare(settings, launch: launch, inputs: WebUpdates.Inputs(
                files: WebUpdatesStartupTests.work, energy: EnergyPolicySource(), shown: nil, deadlines: deadlines.deadlines,
                appEvents: AppEvents(center: NotificationCenter()), checkNode: nil))
        }

        /// Waits until the launch check settled: the pages' first request waits for it, and it
        /// makes the updater.
        func launchSettled() async {
            _ = await launch.finished()
            _ = await overlay.root(for: root)
        }

        /// The time left until the booked check's wake (nil: none is booked).
        var booked: Duration? { deadlines.deadlines.nextFire }

        /// Waits until a check is booked again (a check's end books the next one on main).
        func waitForBooking() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while booked == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(booked != nil, "the check booked no next one")
        }

        /// Waits for the next pointer read.
        func nextRead() async {
            for await _ in reads { return }
        }

        /// Whether a pointer read starts within `limit` (wall clock): a bound on a wait that must
        /// find nothing, so it ends the stream's use in a test.
        func readStarts(within limit: Duration) async -> Bool {
            let reads = reads
            let read = await Deadline(limit, ledger: WakeupLedger()).value("WebUpdatesStartupTests.read") { () async -> Bool in
                for await _ in reads { return true }
                return false
            }
            return read ?? false
        }
    }

    /// Startup completes after the launch read made the updater: the updater is made held, and
    /// ``WebUpdates/startChecks()`` releases it into one read at once.
    @Test func startupCompletingAfterTheLaunchReadReleasesTheHeldUpdater() async throws {
        let rig = try Rig()
        rig.prepare()
        await rig.launchSettled()
        let updater = try #require(rig.web.updater, "the launch read made no updater")
        #expect(updater.channel == .everyMerge)
        #expect(updater.checksHeld, "an updater made before startup completed was not held")
        #expect(rig.booked == nil, "a held updater booked a check")
        // test-deadline: a bound on a wait that must find nothing, not a settle
        #expect(await rig.readStarts(within: .milliseconds(300)) == false, "the pointer was read before startup completed")
        #expect(rig.readCount.count == 0)

        rig.web.startChecks()
        #expect(!updater.checksHeld)
        #expect(rig.booked != nil, "no check was booked")
        rig.deadlines.fireAndRun()
        await rig.nextRead()
        try await rig.waitForBooking()
        #expect(rig.readCount.count == 1)
        // The next read waits an interval (a minute in the front, ten behind other apps).
        #expect((rig.booked ?? .zero) >= .seconds(60))
        updater.noteShown(false)
    }

    /// Startup completes before the launch read made the updater: the updater is made unheld and
    /// its channel follow reads the pointer once at once.
    @Test func startupCompletingBeforeTheLaunchReadMakesAnUnheldUpdater() async throws {
        let rig = try Rig()
        rig.prepare()
        // The updater is made on the main actor after the launch read lands, so not in this turn.
        rig.web.startChecks()
        #expect(rig.web.updater == nil, "the updater was made before startup completed")
        await rig.launchSettled()
        let updater = try #require(rig.web.updater, "the launch read made no updater")
        #expect(!updater.checksHeld, "an updater made after startup completed was held")
        #expect(rig.booked != nil, "no check was booked")
        rig.deadlines.fireAndRun()
        await rig.nextRead()
        try await rig.waitForBooking()
        #expect(rig.readCount.count == 1)
        // The next read waits an interval (a minute in the front, ten behind other apps).
        #expect((rig.booked ?? .zero) >= .seconds(60))
        updater.noteShown(false)
    }
}
