@testable import CmuxNextApp
import CmuxNextLaunch
import Darwin
import Foundation
import Testing

/// p08-startup-108: the first launch came from the run marker (no `run.json` from a previous run), but a normal quit
/// removes `run.json`, so every launch after a clean quit was a first launch and its startup was flagged interrupted.
/// The first launch is now the absence of a first-run sentinel that nothing removes (Chrome's
/// `first_run::IsChromeFirstRun`, chrome/browser/first_run/first_run.cc). No handlers are installed here.
@Suite("Run marker launch read: first run")
struct AppRunMarkerFirstRunTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "run-marker-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The launch read in `folder` alone, its files closed: a launch that ends before its marker is made.
    private static func read(_ folder: URL) -> AppRunMarker.Launch {
        let launch = AppRunMarker.prepareLaunch(directory: folder, now: Date(), bootSession: nil)
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        return launch
    }

    /// One launch that makes its marker: the read, then what the marker's writer does first.
    private static func launch(_ folder: URL) throws -> AppRunMarker.Launch {
        let launch = read(folder)
        guard launch.failure == nil else { return launch }
        AppRunMarker.takeOverCrashFiles(of: launch)
        try RunMarkerFile.replaceAtomically(AppRunMarker.encode(launch.marker), to: folder.appending(path: "run.json"))
        return launch
    }

    /// What a normal quit leaves (`RunMarkerFile.close`): no `run.json`, `run.signal` or `run.launch`.
    private static func cleanQuit(_ folder: URL) {
        for name in ["run.json", "run.signal", AppRunMarker.beaconName] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private static func sentinel(_ folder: URL) -> URL { FirstRunSentinel(directory: folder).url }

    @Test("A clean quit then a relaunch is not a first launch")
    func aRelaunchAfterACleanQuitIsNotFirst() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try Self.launch(folder)
        #expect(first.isFirstRun)
        #expect(FileManager.default.fileExists(atPath: Self.sentinel(folder).path), "the first launch's marker writes the sentinel")
        Self.cleanQuit(folder)
        let next = try Self.launch(folder)
        #expect(next.previous == nil, "a clean quit leaves no marker")
        #expect(!next.isFirstRun)
    }

    @Test("A crash that leaves a marker is not a first launch")
    func aLaunchAfterACrashIsNotFirst() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try "\(SIGSEGV)\n".write(to: folder.appending(path: "run.signal"), atomically: false, encoding: .utf8)
        let next = try Self.launch(folder)
        #expect(next.previous?.signal == SIGSEGV)
        #expect(!next.isFirstRun)
    }

    @Test("Only a missing sentinel makes a first launch")
    func onlyAMissingSentinelIsFirst() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try Self.launch(folder)
        try FileManager.default.removeItem(at: Self.sentinel(folder))
        let withMarker = try Self.launch(folder)
        #expect(withMarker.previous != nil)
        #expect(withMarker.isFirstRun, "a previous run's marker does not stand in for the sentinel")
        Self.cleanQuit(folder)
        #expect(!Self.read(folder).isFirstRun, "the sentinel alone, with no marker, is not a first launch")
    }

    @Test("A first launch that ends before its marker leaves the next launch first")
    func aFirstLaunchWithNoMarkerStaysFirst() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Self.read(folder).isFirstRun)
        #expect(!FileManager.default.fileExists(atPath: Self.sentinel(folder).path), "the read writes no sentinel")
        #expect(try Self.launch(folder).isFirstRun)
    }
}
