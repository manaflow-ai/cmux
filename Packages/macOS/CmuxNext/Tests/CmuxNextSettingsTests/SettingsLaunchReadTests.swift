import AppKit
import CmuxNextActions
import CmuxNextDesignTokens
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// p08-startup 025: the settings launch read starts in `main()` on the files lane (first-launch file
/// creation, read, parse and managed layers), and the launch steps that need it run in a continuation
/// on its completion: never a wait on the main thread, never a step run with the defaults first.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SettingsLaunchReadTests {
    static let work = BackgroundWork(label: "test.settings-launch-read")

    /// A settings file in a fresh directory holding `text`.
    static func file(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "settings-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A first-launch step that records its thread and, on a cold disk, holds until released.
    final class ColdDisk: Sendable {
        let gate = DispatchSemaphore(value: 0)
        let threads = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation

        init() { (started, startedContinuation) = AsyncStream.makeStream(of: Void.self) }

        func prepare(_ url: URL, held: Bool) -> @Sendable () throws -> URL {
            { [self] in
                threads.withLock { $0.append(Thread.isMainThread) }
                startedContinuation.yield()
                if held { gate.wait() }
                return url
            }
        }
    }

    /// What the continuation ran, in order (main actor).
    @MainActor final class Steps { var names: [String] = [] }

    /// A main hop the test drains by hand; `arrived` yields each time the lane hands it a job.
    final class HandHop: Sendable {
        let queued = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])
        let arrived: AsyncStream<Void>
        private let arrival: AsyncStream<Void>.Continuation

        init() { (arrived, arrival) = AsyncStream.makeStream(of: Void.self) }

        var hop: StartupMainHop {
            StartupMainHop { [self] job in
                queued.withLock { $0.append(job) }
                arrival.yield()
            }
        }

        /// Runs every queued job.
        @MainActor func drain() {
            for job in queued.withLock({ queued in defer { queued = [] }; return queued }) { job() }
        }
    }

    /// The main hop of a test that only needs the read: the job runs in a later main-actor turn.
    static let laterTurn = StartupMainHop { job in Task { @MainActor in job() } }

    /// A managed reader that counts its reads (CFPreferences IPC in the app).
    final class CountingManagedReader: ManagedPreferenceReader {
        let preferences: ManagedPreferences
        let reads = OSAllocatedUnfairLock(initialState: 0)

        init(_ preferences: ManagedPreferences) { self.preferences = preferences }

        func read() -> ManagedPreferences {
            reads.withLock { $0 += 1 }
            return preferences
        }
    }

    /// The launch read of `pending`, once it ended.
    static func ended(_ pending: SettingsController.PendingLaunchRead) async throws -> SettingsController.LaunchRead {
        let (ran, done) = AsyncStream.makeStream(of: SettingsController.LaunchRead.self)
        pending.whenRead(hop: laterTurn, startup: StartupTestScheduler().startup, take: { _ in }, then: { done.yield($0) })
        var reads = ran.makeAsyncIterator()
        return try #require(await reads.next(), "the steps never ran after the read ended")
    }

    /// The launch read of the file at `url` with `managed` as the managed layer, once it ended.
    static func endedRead(of url: URL, managed: ManagedPreferences = ManagedPreferences()) async throws -> SettingsController.LaunchRead {
        try await ended(SettingsController.startLaunchRead(on: work, prepareFileURL: { url }, managedReader: FixedManagedPreferenceReader(managed)))
    }

    /// The cold launch, driven as `AppDelegate` drives it: `take` primes the theme as the critical
    /// `Settings.takeLaunchRead` step, `then` builds the window and commits its first frame. While the
    /// read is held nothing runs and no frame commits; once it lands the take runs before the commit.
    @Test func onAColdDiskNoStepAndNoCommitComeBeforeTheTakeAndMainNeverWaits() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "compact" } }"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ColdDisk()
        defer { disk.gate.signal() }  // never leaves a lane thread held, whatever fails
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: disk.prepare(url, held: true),
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        for await _ in disk.started { break }
        let s = StartupTestScheduler()
        let hand = HandHop()
        let steps = Steps()
        pending.whenRead(hop: hand.hop, startup: s.startup, take: { read in
            steps.names.append("take(\(read.snapshot.density ?? "defaults"))")
        }, then: { _ in
            steps.names.append("window")
            s.startup.firstFrameCommitted()
        })
        // whenRead returned while the read is held on its lane: the main thread did not wait for it.
        #expect(steps.names.isEmpty, "a settings step ran before the read ended (a frame in the defaults)")
        #expect(pending.value == nil)
        #expect(!s.startup.log.records.contains { $0.name.description == "Settings.takeLaunchRead" })
        #expect(s.startup.log.phase == .beforeFirstFrame, "a frame committed while the settings read was held")
        disk.gate.signal()
        for await _ in hand.arrived { break }
        #expect(steps.names.isEmpty, "the continuation ran on the lane's thread, not in a main turn")
        hand.drain()
        #expect(steps.names == ["take(compact)", "window"], "the window was built before the theme took the file's settings")
        let take = try #require(s.startup.log.records.first { $0.name.description == "Settings.takeLaunchRead" })
        #expect(take.priority == .critical)
        #expect(take.violation == nil)
        #expect(take.startNanos != nil, "the take did not run as a startup step")
        #expect(s.startup.log.phase == .afterFirstFrame)
        #expect(disk.threads.withLock { $0 } == [false], "the first-launch step or the read ran on the main thread")
    }

    @Test func aReadThatEndedRunsTheStepsInTheSameTurn() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "cozy" } }"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ColdDisk()
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: disk.prepare(url, held: false),
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        _ = try await Self.ended(pending)
        let steps = Steps()
        let later = StartupMainHop { _ in Issue.record("an ended read hopped to a later turn") }
        pending.whenRead(hop: later, startup: StartupTestScheduler().startup, take: { steps.names.append("take.\($0.snapshot.density ?? "")") },
                         then: { _ in steps.names.append("then") })
        #expect(steps.names == ["take.cozy", "then"], "an ended read did not run the steps at once")
    }

    /// The app reads the incognito ledger, then the settings, in one sequence: the launch window the settings
    /// read's landing builds knows the ledger's answer, although the files lane runs other user-blocking reads at once.
    @Test func aSequencedReadStartsOnlyOnceTheReadBeforeItHasItsResult() async throws {
        let url = try Self.file("{}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The app's widths: four user-blocking files slots.
        let work = BackgroundWork(label: "test.settings-launch-sequence")
        let reads = work.sequence("test.ledger-then-settings")
        let ledger = CmuxNextWakeups.LaunchRead<Int>(in: reads) {
            // A cold disk: outside the sequence, the settings read would start meanwhile on another slot.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(100))
            return 1
        }
        let seen = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let pending = SettingsController.startLaunchRead(on: work, in: reads, prepareFileURL: {
            seen.withLock { $0 = ledger.value ?? 0 }
            return url
        }, managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        _ = try await Self.ended(pending)
        #expect(seen.withLock { $0 } == 1, "the settings read started before the ledger read had its result")
    }

    @Test func aFailedFirstLaunchReadsTheDefaultPathAndSaysWhy() async throws {
        let fallback = try Self.file(#"{ "appearance": { "density": "spacious" } }"#)
        defer { try? FileManager.default.removeItem(at: fallback.deletingLastPathComponent()) }
        struct ReadOnlyHome: Error {}
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: { throw ReadOnlyHome() },
                                                         fallbackURL: { fallback },
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        let read = try await Self.ended(pending)
        #expect(read.fileURL == fallback)
        #expect(read.snapshot.density == "spacious")
        #expect(read.bootstrapFailure?.contains("ReadOnlyHome") == true)
    }

    /// The MDM status file is never written at launch by the controller itself: each write goes to the
    /// poster the app gives (an afterStartup files-lane task), in order.
    @Test func theManagedStatusWriteGoesToItsPosterNotTheLaunch() async throws {
        let url = try Self.file("{}")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try await Self.endedRead(of: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [],
                                          launch: launch)
        let status = directory.appending(path: "status/managed-status.json")
        var posted: [@Sendable () -> Void] = []
        settings.writeManagedStatus(to: status, context: .init(appVersion: "1", bundleID: "test")) { posted.append($0) }
        settings.start()
        defer { settings.stop() }
        #expect(posted.count == 1, "the launch load did not post its status write")
        #expect(!FileManager.default.fileExists(atPath: status.path), "the status file was written before its post ran")
        posted.forEach { $0() }
        #expect(FileManager.default.fileExists(atPath: status.path), "the posted write did not write the status file")
    }

    /// The launch steps that read the managed policy (`applyManagedFeaturesNow`, the policy bridge's
    /// first apply) use the launch read's managed layer: no CFPreferences read on the main thread.
    @Test func launchStepsReadTheManagedPolicyFromTheLaunchRead() async throws {
        let url = try Self.file("{}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disabled = JSONValue.array([.string(ActionFeature.cloud.rawValue)])
        let policy = ManagedPreferences(forced: ["DisabledFeatures": disabled])
        let launch = try await Self.endedRead(of: url, managed: policy)
        let reader = CountingManagedReader(policy)
        let registry = ActionRegistry(catalog: [])
        let settings = SettingsController(registry: registry, fileURL: url, managedReader: reader, managedWatchFiles: [], launch: launch)
        settings.applyManagedFeaturesNow()
        let forced = settings.forcedManagedValuesNow()
        #expect(registry.disabledFeatures == [.cloud])
        #expect(forced["DisabledFeatures"] == disabled)
        #expect(reader.reads.withLock { $0 } == 0, "a launch step read the managed preferences again on the main thread")
    }

    /// p08-startup-079: the launch applies its read as the first load before any watch (the first frame in the
    /// file's look, no read on the main thread, the MDM status posted), and the watches the app arms after the first
    /// frame reload once, so an edit made in between applies.
    @Test func theLaunchReadAppliesBeforeTheWatchesAndAnEditInBetweenApplies() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "compact" } }"#)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = try await Self.endedRead(of: url)
        let reader = CountingManagedReader(ManagedPreferences())
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url, managedReader: reader, managedWatchFiles: [],
                                          launch: launch)
        var posted = 0
        settings.writeManagedStatus(to: directory.appending(path: "status.json"), context: .init(appVersion: "1", bundleID: "test")) { _ in posted += 1 }
        settings.adoptLaunchRead()
        #expect(settings.loadCount == 1)
        #expect(settings.snapshot.density == "compact", "the first frame would draw in the defaults")
        #expect(reader.reads.withLock { $0 } == 0, "the adopt read the managed preferences on the main thread")
        #expect(posted == 1, "the launch load did not post its MDM status")
        settings.adoptLaunchRead()
        #expect(settings.loadCount == 1, "a second adopt loaded again")
        try Data(#"{ "appearance": { "density": "cozy" } }"#.utf8).write(to: url)
        settings.start()
        defer { settings.stop() }
        await settings.waitForLoad(atLeast: 2)
        #expect(settings.snapshot.density == "cozy", "an edit made before the watches were armed did not apply")
    }

    /// A controller made without a launch read adopts nothing: no file or managed read on the calling thread.
    @Test func withoutALaunchReadTheAdoptLoadsNothing() {
        let reader = CountingManagedReader(ManagedPreferences())
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: URL(filePath: "/nonexistent/cmux-next.json"),
                                          managedReader: reader, managedWatchFiles: [])
        settings.adoptLaunchRead()
        #expect(settings.loadCount == 0)
        #expect(reader.reads.withLock { $0 } == 0, "the adopt read the managed preferences")
    }

    /// The activation backstop for MDM profile changes: each app activation reloads, through the
    /// app's one activation observer.
    @Test func anActivationAfterFollowActivationReloads() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "compact" } }"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        settings.followActivation(on: events)
        #expect(events.subscriberCount(NSApplication.didBecomeActiveNotification) == 1)
        #expect(settings.loadCount == 0)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settings.waitForLoad(atLeast: 1)
        #expect(settings.snapshot.density == "compact", "the activation did not reload the settings")
    }
}
