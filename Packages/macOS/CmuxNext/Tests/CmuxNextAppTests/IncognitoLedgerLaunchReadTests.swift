@testable import CmuxNextApp
import CmuxNextDesign
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
        let crashed = IncognitoWorkspaceLedger(url: left, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: left, on: Self.work))
        #expect(await crashed.load() == ["w1", "w2"])
        try FileManager.default.removeItem(at: left)
        #expect(crashed.mayHaveLeftovers, "the file went after the launch read; the check must not look again")

        let clean = folder.appending(path: "clean.json")
        let ledger = IncognitoWorkspaceLedger(url: clean, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: clean, on: Self.work))
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
        let dropped = LaunchRead<[String]>(on: work, shutdown: .skipOnShutdown) { [] }
        let ledger = IncognitoWorkspaceLedger(url: URL(filePath: "/nonexistent/incognito-workspaces.json"), leftovers: dropped)
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
        let ledger = IncognitoWorkspaceLedger(url: url, leftovers: IncognitoWorkspaceLedger.startLaunchRead(at: url, on: work))
        #expect(await ledger.load() == ["w"])
        await work.shutdown()
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
