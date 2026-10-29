@testable import CmuxNextApp
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Testing

/// `AppRunMarker.init` read the previous run's `run.json`, `run.signal` and `run.exception`, then
/// made the folder and opened this run's files, all on the main thread inside `AppServices.init`. The launch read now
/// does the reads and opens on a files lane from `main`, and changes none of the previous run's files: the marker's
/// writer replaces them once the marker is made. Recovery stays as it was for a clean quit, one crash, two quick
/// crashes in a row, and a launch that ends before its marker. These tests take the read with no handlers installed
/// (the exit-test children in CrashMarkerChildTests install them).
@Suite("Run marker launch read: recovery")
struct AppRunMarkerLaunchRecoveryTests {
    private static let boot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "run-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The launch read in `folder` alone, its files closed: a launch that ends before its marker is made.
    private static func read(_ folder: URL) -> AppRunMarker.Launch {
        let launch = AppRunMarker.prepareLaunch(directory: folder, now: Date(), bootSession: boot)
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        return launch
    }

    /// One launch in `folder` that makes its marker: the read, then what the marker's writer does first (the crash
    /// files' takeover and this run's `run.json`), with no handlers installed.
    private static func launch(_ folder: URL) throws -> AppRunMarker.Launch {
        let launch = read(folder)
        guard launch.failure == nil else { return launch }
        AppRunMarker.takeOverCrashFiles(of: launch)
        try RunMarkerFile.replaceAtomically(AppRunMarker.encode(launch.marker), to: folder.appending(path: "run.json"))
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
        let first = try Self.launch(folder)
        #expect(first.failure == nil)
        #expect(first.recovery == .clean && first.previousExit == nil)
        #expect(!first.marker.recovery)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path), "this run is marked on disk")
        // A clean exit removes the marker and the signal file (RunMarkerFile.close).
        try FileManager.default.removeItem(at: folder.appending(path: "run.json"))
        try FileManager.default.removeItem(at: folder.appending(path: "run.signal"))
        #expect(try Self.launch(folder).recovery == .clean)
    }

    @Test("One crash restores everything; a second quick crash restores without browser pages")
    func oneAndTwoCrashes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try Self.crash(folder)
        let afterOne = try Self.launch(folder)
        guard case .restarted(let run) = afterOne.recovery else {
            Issue.record("one crash: \(afterOne.recovery)")
            return
        }
        #expect(run.signal == SIGSEGV)
        #expect(afterOne.previousExit == .crash)
        #expect(afterOne.marker.recovery, "the run after a crash watches for a restart loop")
        try Self.crash(folder)
        let afterTwo = try Self.launch(folder)
        #expect(afterTwo.recovery.skipsBrowserPages, "two quick crashes: \(afterTwo.recovery)")
    }

    @Test("A requested quit that was killed is clean")
    func aRequestedQuitIsClean() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try "\(SIGTERM)\n".write(to: folder.appending(path: "run.signal"), atomically: false, encoding: .utf8)
        #expect(try Self.launch(folder).recovery == .clean)
    }

    /// A quit or kill before `AppServices` exists (Ctrl-C, dev tooling's SIGTERM, logout during launch) leaves no
    /// marker of its own: the next launch is clean, not a kill (stability.unclean_exit) nor a restart.
    @Test("A launch that ends before its marker is made leaves the next launch clean")
    func aLaunchWithNoMarkerLeavesNoRecord() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ended = Self.read(folder)
        #expect(ended.failure == nil && ended.signalDescriptor >= 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path), "the read writes no marker")
        let next = try Self.launch(folder)
        #expect(next.recovery == .clean)
        #expect(next.previousExit == nil)
        #expect(!next.marker.recovery)
    }

    /// After a crash, a launch that ends before its marker leaves that crash for the next launch to decide on, with
    /// its signal, exception and crash keys.
    @Test("A launch that ends before its marker leaves the previous crash as it was")
    func aLaunchWithNoMarkerKeepsThePreviousCrash() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try Self.crash(folder)
        try "crash_keys action_id=7\n".write(to: folder.appending(path: "run.crashkeys"), atomically: false, encoding: .utf8)
        try JSONEncoder().encode(RecordedException(name: "NSRangeException", reason: "r", frames: []))
            .write(to: folder.appending(path: "run.exception"))
        let ended = Self.read(folder)
        let next = try Self.launch(folder)
        for launch in [ended, next] {
            guard case .restarted(let run) = launch.recovery else {
                Issue.record("after the crash: \(launch.recovery)")
                continue
            }
            #expect(run.signal == SIGSEGV)
            #expect(run.exception?.name == "NSRangeException")
            #expect(launch.previousExit == .crash)
            #expect(launch.previousCrashKeys?.snapshot.actionID == 7)
        }
    }

    @Test("The marker's takeover empties this run's files, drops the old exception and keeps the old keys in memory")
    func theTakeoverPreparesThisRunsFiles() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try "crash_keys action_id=1\n".write(to: folder.appending(path: "run.crashkeys"), atomically: false, encoding: .utf8)
        try JSONEncoder().encode(RecordedException(name: "NSRangeException", reason: "r", frames: []))
            .write(to: folder.appending(path: "run.exception"))
        try Self.crash(folder)
        let next = try Self.launch(folder)
        #expect(next.previous?.exception?.name == "NSRangeException", "the exception was read before it was removed")
        #expect(next.previousCrashKeys?.snapshot.actionID == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "run.exception").path))
        #expect(try Data(contentsOf: folder.appending(path: "run.crashkeys")).isEmpty)
        #expect(try Data(contentsOf: folder.appending(path: "run.signal")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: AppRunMarker.spareSignalName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: AppRunMarker.spareCrashKeysName).path))
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
