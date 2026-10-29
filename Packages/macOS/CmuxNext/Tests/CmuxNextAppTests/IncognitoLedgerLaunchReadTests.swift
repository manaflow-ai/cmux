@testable import CmuxNextApp
import CmuxNextDesign
import AppKit
import CmuxNextWakeups
import Foundation
import Testing

/// p08-startup 038 (Q5): the launch window's incognito check (`LaunchSnapshotWindow.showEveryWorkspace`) made a
/// `stat` of the ledger file on the main thread inside the launch turn. The ledger is now read once on a launch
/// lane from `main`; the check and the restore read that result, and the main thread never touches the file.
@Suite("Incognito ledger read on a launch lane", .serialized)
@MainActor
struct IncognitoLedgerLaunchReadTests {
    static let work = BackgroundWork(label: "test.incognito-ledger")

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "incognito-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func write(_ ids: [String], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: ["workspaces": ids]).write(to: url)
    }

    /// Before the change the check was a `fileExists` at call time, so a file that appears or goes after the
    /// launch read changed its answer: here it keeps the launch read's, so it made no disk call.
    @Test("The launch window's check answers from the launch read, not the disk")
    func theCheckAnswersFromTheLaunchRead() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appending(path: "left.json")
        try Self.write(["w1", "w2"], to: left)
        let crashed = IncognitoWorkspaceLedger(url: left, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: left, on: Self.work), work: Self.work)
        #expect(await crashed.load() == ["w1", "w2"])
        try FileManager.default.removeItem(at: left)
        #expect(crashed.mayHaveLeftovers, "the file went after the launch read; the check must not look again")

        let clean = folder.appending(path: "clean.json")
        let ledger = IncognitoWorkspaceLedger(url: clean, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: clean, on: Self.work), work: Self.work)
        #expect(await ledger.load().isEmpty)
        try Self.write(["late"], to: clean)
        #expect(!ledger.mayHaveLeftovers, "a file made after the launch read is this run's, not the last run's")
    }

    /// The launch window must never list workspaces that may be incognito: a read with no result yet counts as
    /// leftovers. A skip-on-shutdown read posted after quit began never runs, so its result never comes.
    @Test("While the launch read has no result the check says the last run may have left some")
    func aReadWithNoResultMayHaveLeftovers() async {
        let work = BackgroundWork(label: "test.incognito-ledger-dropped")
        work.beginShutdown()
        let dropped = LaunchRead<IncognitoWorkspaceLedger.Leftovers>(on: work, shutdown: .skipOnShutdown) { .noFile }
        let ledger = IncognitoWorkspaceLedger(url: URL(filePath: "/nonexistent/incognito-workspaces.json"), leftovers: dropped, work: Self.work)
        #expect(ledger.mayHaveLeftovers)
        await work.shutdown()
        #expect(dropped.value == nil && ledger.mayHaveLeftovers)
    }

    /// The restore awaits the read, so a quit that begins before it starts must not leave it waiting forever.
    @Test("A launch read posted as quit begins still finishes", .timeLimit(.minutes(1)))
    func aReadAtQuitStillFinishes() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "incognito-workspaces.json")
        try Self.write(["w"], to: url)
        let work = BackgroundWork(label: "test.incognito-ledger-quit")
        work.beginShutdown()
        let ledger = IncognitoWorkspaceLedger(url: url, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: url, on: work), work: work)
        #expect(await ledger.load() == ["w"])
        await work.shutdown()
    }

    /// The old check was `fileExists`, so any ledger file kept the launch window from listing every workspace. A
    /// file the read cannot decode must do the same (fail closed), while the restore has no id to close.
    @Test("A ledger file that cannot be read still counts as leftovers")
    func anUnreadableFileMayHaveLeftovers() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrupt = folder.appending(path: "incognito-workspaces.json")
        try Data("{\"workspaces\": [".utf8).write(to: corrupt)
        let ledger = IncognitoWorkspaceLedger(url: corrupt, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: corrupt, on: Self.work), work: Self.work)
        #expect(await ledger.load().isEmpty)
        #expect(ledger.mayHaveLeftovers, "an unreadable ledger may list incognito workspaces")

        let empty = folder.appending(path: "empty.json")
        try Self.write([], to: empty)
        let listsNone = IncognitoWorkspaceLedger(url: empty, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: empty, on: Self.work), work: Self.work)
        #expect(await listsNone.load().isEmpty)
        #expect(!listsNone.mayHaveLeftovers)
    }

    /// Before the fix a block-shutdown read posted after `shutdown()` returned was refused and never resumed its
    /// waiters, so the restore's `await load()` hung (a quit during launch, then the daemon snapshot lands).
    @Test("A launch read refused after shutdown ends with no ids", .timeLimit(.minutes(1)))
    func aReadRefusedAfterShutdownEnds() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "incognito-workspaces.json")
        try Self.write(["w"], to: url)
        let work = BackgroundWork(label: "test.incognito-ledger-refused")
        await work.shutdown()
        let ledger = IncognitoWorkspaceLedger(url: url, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: url, on: work), work: work)
        #expect(await ledger.load().isEmpty)
        #expect(ledger.mayHaveLeftovers, "the file was never read: it may list incognito workspaces")
    }

    /// The window manager's ledger takes `main`'s read from the environment as `AppServices` is built, so the
    /// launch window and the restore read the result `main` started.
    @Test("The window manager's ledger reads main's launch read")
    func theManagerUsesMainsRead() async {
        _ = NSApplication.shared
        let mains = LaunchRead<IncognitoWorkspaceLedger.Leftovers>(on: Self.work) { .ids(["from-main"], spaces: []) }
        _ = await mains.finished()
        var environment = AppEnvironment.current([:])
        environment.incognitoLeftovers = mains
        let services = AppServices(environment: environment)
        #expect(services.windows.incognitoLedger.mayHaveLeftovers)
        #expect(await services.windows.incognitoLedger.load() == ["from-main"])
    }

    /// The ledger lives in Application Support under the bundle id; making its path reads no file.
    @Test("The ledger's path is under the bundle id")
    func theLedgerPath() {
        #expect(IncognitoWorkspaceLedger.standardURL(bundleIdentifier: "com.example.tag").path
            .hasSuffix("/com.example.tag/incognito-workspaces.json"))
        #expect(IncognitoWorkspaceLedger.standardURL(bundleIdentifier: "").path
            .hasSuffix("/com.cmuxterm.app.next/incognito-workspaces.json"))
    }
}
