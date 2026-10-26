@testable import CmuxNextApp
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Testing

/// p08-startup-075: `AppRunMarker.init` read the previous run's `run.json`, `run.signal` and `run.exception`, then
/// made the folder and opened this run's files, all on the main thread inside `AppServices.init`. The launch read now
/// does that on a files lane from `main`; the decisions take its result. Recovery stays as it was for a clean quit,
/// one crash and two quick crashes in a row. These tests take the read with no handlers installed (the exit-test
/// children in CrashMarkerChildTests install them).
@Suite("Run marker launch read: recovery")
struct AppRunMarkerLaunchRecoveryTests {
    private static let boot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "run-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One launch in `folder`: the read's result, its files closed.
    private static func launch(_ folder: URL) -> AppRunMarker.Launch {
        let launch = AppRunMarker.prepareLaunch(directory: folder, now: Date(), bootSession: boot)
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        return launch
    }

    /// The run that `folder`'s marker describes crashes on SIGSEGV (its handler's write).
    private static func crash(_ folder: URL) throws {
        try "\(SIGSEGV)\n".write(to: folder.appending(path: "run.signal"), atomically: false, encoding: .utf8)
    }

    @Test("A first launch and a launch after a clean quit are clean")
    func cleanLaunches() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Self.launch(folder)
        #expect(first.failure == nil)
        #expect(first.recovery == .clean && first.previousExit == nil)
        #expect(!first.marker.recovery)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path), "this run is marked on disk")
        // A clean exit removes the marker and the signal file (RunMarkerFile.close).
        try FileManager.default.removeItem(at: folder.appending(path: "run.json"))
        try FileManager.default.removeItem(at: folder.appending(path: "run.signal"))
        #expect(Self.launch(folder).recovery == .clean)
    }

    @Test("One crash restores everything; a second quick crash restores without browser pages")
    func oneAndTwoCrashes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = Self.launch(folder)
        try Self.crash(folder)
        let afterOne = Self.launch(folder)
        guard case .restarted(let run) = afterOne.recovery else {
            Issue.record("one crash: \(afterOne.recovery)")
            return
        }
        #expect(run.signal == SIGSEGV)
        #expect(afterOne.previousExit == .crash)
        #expect(afterOne.marker.recovery, "the run after a crash watches for a restart loop")
        try Self.crash(folder)
        let afterTwo = Self.launch(folder)
        #expect(afterTwo.recovery.skipsBrowserPages, "two quick crashes: \(afterTwo.recovery)")
    }

    @Test("A requested quit that was killed is clean")
    func aRequestedQuitIsClean() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = Self.launch(folder)
        try "\(SIGTERM)\n".write(to: folder.appending(path: "run.signal"), atomically: false, encoding: .utf8)
        #expect(Self.launch(folder).recovery == .clean)
    }

    @Test("The read moves the last run's crash keys aside, empties this run's files and drops the old exception")
    func theReadPreparesThisRunsFiles() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = Self.launch(folder)
        try "crash_keys action_id=1\n".write(to: folder.appending(path: "run.crashkeys"), atomically: false, encoding: .utf8)
        try JSONEncoder().encode(RecordedException(name: "NSRangeException", reason: "r", frames: []))
            .write(to: folder.appending(path: "run.exception"))
        try Self.crash(folder)
        let next = Self.launch(folder)
        #expect(next.previous?.exception?.name == "NSRangeException", "the exception was read before it was removed")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.exception").path))
        #expect(try String(contentsOf: folder.appending(path: "run.crashkeys.previous"), encoding: .utf8) == "crash_keys action_id=1\n")
        #expect(try Data(contentsOf: folder.appending(path: "run.crashkeys")).isEmpty)
        #expect(try Data(contentsOf: folder.appending(path: "run.signal")).isEmpty)
    }

    @MainActor
    @Test("Started from the main thread, the read runs on a lane")
    func theReadRunsOffMain() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let onMain = OnMainRecord(), boot = Self.boot
        let read = AppRunMarker.startLaunchRead(directory: folder, in: BackgroundWork(label: "test.run-marker-lane").sequence("test"),
                                                bootSession: { onMain.note(); return boot })
        let launch = await read.finished()
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        #expect(onMain.values == [false])
        #expect(launch.bootSession == boot)
        #expect(launch.failure == nil && launch.signalDescriptor >= 0)
    }
}

/// Whether each call of ``note()`` ran on the main thread.
private nonisolated final class OnMainRecord: Sendable {
    private let calls = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    func note() { calls.withLock { $0.append(Thread.isMainThread) } }
    var values: [Bool] { calls.withLock { $0 } }
}
