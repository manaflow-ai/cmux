import CmuxNextActions
import CmuxNextWakeups
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

    /// The main hop of a test: the job runs in a later main-actor turn, as the scheduler's post does.
    static let hop: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { job in Task { @MainActor in job() } }

    @Test func onAColdDiskTheStepsWaitForTheReadWithNoMainWaitAndNoDefaults() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "compact" } }"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ColdDisk()
        defer { disk.gate.signal() }  // never leaves a lane thread held, whatever fails
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: disk.prepare(url, held: true),
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        for await _ in disk.started { break }
        let (ran, done) = AsyncStream.makeStream(of: SettingsController.LaunchRead.self)
        let steps = Steps()
        pending.whenRead(hop: Self.hop) { read in
            steps.names.append("theme")  // the window steps follow the theme in the continuation
            done.yield(read)
        }
        // whenRead returned while the read is held on its lane: the main thread did not wait for it.
        #expect(steps.names.isEmpty, "a settings step ran before the read ended (a frame in the defaults)")
        #expect(pending.value == nil)
        disk.gate.signal()
        var reads = ran.makeAsyncIterator()
        let read = try #require(await reads.next(), "the steps never ran after the read ended")
        #expect(steps.names == ["theme"])
        #expect(read.snapshot.density == "compact", "the steps did not get the file's settings")
        #expect(read.fileURL == url)
        #expect(read.bootstrapFailure == nil)
        #expect(disk.threads.withLock { $0 } == [false], "the first-launch step or the read ran on the main thread")
    }

    @Test func aReadThatEndedRunsTheStepsInTheSameTurn() async throws {
        let url = try Self.file(#"{ "appearance": { "density": "cozy" } }"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ColdDisk()
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: disk.prepare(url, held: false),
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        let (ended, done) = AsyncStream.makeStream(of: Void.self)
        pending.whenRead(hop: Self.hop) { _ in done.yield() }
        for await _ in ended { break }
        let steps = Steps()
        pending.whenRead(hop: { _ in Issue.record("an ended read hopped to a later turn") }) { steps.names.append($0.snapshot.density ?? "") }
        #expect(steps.names == ["cozy"], "an ended read did not run the steps at once")
    }

    @Test func aFailedFirstLaunchReadsTheDefaultPathAndSaysWhy() async throws {
        let fallback = try Self.file(#"{ "appearance": { "density": "spacious" } }"#)
        defer { try? FileManager.default.removeItem(at: fallback.deletingLastPathComponent()) }
        struct ReadOnlyHome: Error {}
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: { throw ReadOnlyHome() },
                                                         fallbackURL: { fallback },
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        let (ran, done) = AsyncStream.makeStream(of: SettingsController.LaunchRead.self)
        pending.whenRead(hop: Self.hop) { done.yield($0) }
        var reads = ran.makeAsyncIterator()
        let read = try #require(await reads.next())
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
        let pending = SettingsController.startLaunchRead(on: Self.work, prepareFileURL: { url },
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences()))
        let (ran, done) = AsyncStream.makeStream(of: SettingsController.LaunchRead.self)
        pending.whenRead(hop: Self.hop) { done.yield($0) }
        var reads = ran.makeAsyncIterator()
        let launch = try #require(await reads.next())
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
}
