@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCrashReporting
import Darwin
import Foundation
import Sentry
import Testing

/// role-aware: the `cef.fatal` tag comes from the log of the process that ran
/// `CefInitialize`, written while it ran: the app's own log for the app's crash event, the host's for the host's.
struct CEFFatalLineRoleTests {
    private static let pid: Int32 = 4242
    private static let launched = Date(timeIntervalSince1970: 1_790_000_000)
    /// This launch, ten minutes later.
    private static let now = launched.addingTimeInterval(600)

    private static func run(pid: Int32 = Self.pid) -> PreviousRun {
        PreviousRun(pid: pid, launched: launched, recovery: false, survived: true, signal: SIGTRAP, quitting: false,
                    bootSession: nil)
    }

    private static func fatal(pid: Int32 = Self.pid, _ location: String, _ message: String = "Check failed: x") -> String {
        "[\(pid):259:1027/101010.123456:FATAL:\(location)] \(message)\n"
    }

    private static func write(_ text: String, to url: URL, modified: Date) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func storage() throws -> CEFProfileStorage {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-fatal-role-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CEFProfileStorage(root: root)
    }

    @Test func theAppsCrashReadsItsOwnLog() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Self.write(Self.fatal("content/browser/a.cc:42"), to: storage.logFile, modified: Self.launched.addingTimeInterval(60))
        let log = try #require(ChromiumFatalLog.app(previous: Self.run(), endedUncleanly: true, launched: Self.now, storage: storage))
        #expect(log.role == .app)
        #expect(log.read()?.tagValue == "FATAL:content/browser/a.cc:42] Check failed: x")
    }

    /// This launch's Chromium start moved the crashed run's log aside and began its own.
    @Test func afterThisLaunchsChromiumStartItReadsTheKeptLog() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Self.write(Self.fatal("content/browser/kept.cc:1"), to: storage.previousLogFile,
                       modified: Self.launched.addingTimeInterval(60))
        try Self.write(Self.fatal(pid: 5555, "content/browser/now.cc:2"), to: storage.logFile,
                       modified: Self.now.addingTimeInterval(5))
        let log = try #require(ChromiumFatalLog.app(previous: Self.run(), endedUncleanly: true, launched: Self.now, storage: storage))
        #expect(log.read()?.path == "content/browser/kept.cc")
    }

    /// A run with Chromium in the host never wrote the app's log: an older run's line is not this crash's.
    @Test func aRunThatDidNotRunChromiumInProcessGetsNoLine() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Self.write(Self.fatal("content/browser/old.cc:1"), to: storage.logFile, modified: Self.launched.addingTimeInterval(-3_600))
        let log = try #require(ChromiumFatalLog.app(previous: Self.run(), endedUncleanly: true, launched: Self.now, storage: storage))
        #expect(log.read() == nil)
    }

    @Test func aRequestedQuitReadsNoLog() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        #expect(ChromiumFatalLog.app(previous: Self.run(), endedUncleanly: false, launched: Self.now, storage: storage) == nil)
    }

    /// The host's own `--log-file`, its pid's lines, from its start until its end.
    @Test func theHostsEndReadsTheHostsLog() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let hostLog = storage.root.appending(path: "chromium-host.log")
        let hostPid: Int32 = 6060
        try Self.write(Self.fatal(pid: hostPid, "content/browser/host.cc:3") + Self.fatal(pid: 7070, "content/renderer/r.cc:4"),
                       to: hostLog, modified: Self.launched.addingTimeInterval(30))
        try Self.write(Self.fatal("content/browser/app.cc:5"), to: storage.logFile, modified: Self.launched.addingTimeInterval(30))
        let log = try #require(ChromiumFatalLog.chromiumHost(logFile: hostLog, pid: hostPid, started: Self.launched,
                                                             ended: Self.launched.addingTimeInterval(31)))
        #expect(log.role == .chromiumHost)
        #expect(log.candidates == [hostLog])
        #expect(log.read()?.path == "content/browser/host.cc")
    }

    /// Acceptance: the previous run's crash event carries the line as `cef.fatal`, with the planted URL redacted.
    @Test func theCrashEventGetsTheTagWithNoURL() throws {
        let storage = try Self.storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Self.write(Self.fatal("content/browser/nav.cc:7", "Check failed: commit of https://bank.example.com/acct?id=99 failed"),
                       to: storage.logFile, modified: Self.launched.addingTimeInterval(60))
        let cefLog = ChromiumFatalLog.app(previous: Self.run(), endedUncleanly: true, launched: Self.now, storage: storage)
        let files = PreviousRunCrashEvidence.Run(pid: UInt32(Self.pid), processStartUnixMicros: nil, traceDirectory: storage.root.path)
        let evidence = PreviousRunCrashEvidence(processStartUnixMicros: nil, read: { blackBox in
            CrashReporter.previousRunFiles(files, cefLog: cefLog, blackBox: blackBox)
        }, hangReportsOptIn: { false })
        let event = Event(level: .fatal)
        evidence.decorate(event, hint: Hint())
        let tag = try #require(event.tags?[CEFFatalLine.tag])
        #expect(tag == "FATAL:content/browser/nav.cc:7] Check failed: commit of <url> failed")
        #expect(!tag.contains("example"))
    }
}
