import Foundation
import Synchronization
@testable import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Every "Show Crash Logs" entrypoint opens the log in TextEdit; Finder
/// only when TextEdit is missing or there is no log file yet.
@Suite struct CrashLogOpenerTests {
    final class Calls: Sendable {
        let opened = Mutex<[(URL, URL)]>([])
        let revealed = Mutex<[URL]>([])
    }

    static func opener(textEdit: URL?, _ calls: Calls) -> CrashLogOpener {
        CrashLogOpener(
            textEditURL: { textEdit },
            openWith: { file, app in calls.opened.withLock { $0.append((file, app)) } },
            reveal: { url in calls.revealed.withLock { $0.append(url) } }
        )
    }

    static let textEdit = URL(filePath: "/System/Applications/TextEdit.app", directoryHint: .isDirectory)

    @Test func aLogOpensInTextEdit() {
        let calls = Calls()
        let log = URL(filePath: "/tmp/cmux-2026-10-04-055634.ips")
        let outcome = Self.opener(textEdit: Self.textEdit, calls).show(log)
        #expect(outcome == .textEdit(log))
        #expect(calls.opened.withLock { $0.map(\.0) } == [log])
        #expect(calls.opened.withLock { $0.map(\.1) } == [Self.textEdit])
        #expect(calls.revealed.withLock { $0 }.isEmpty)
    }

    @Test func withoutTextEditTheLogIsShownInFinder() {
        let calls = Calls()
        let log = URL(filePath: "/tmp/cmux-2026-10-04-055634.ips")
        #expect(Self.opener(textEdit: nil, calls).show(log) == .finder(log))
        #expect(calls.revealed.withLock { $0 } == [log])
        #expect(calls.opened.withLock { $0 }.isEmpty)
    }

    @Test func aFolderOpensInFinder() {
        let calls = Calls()
        let folder = URL(filePath: "/tmp/reports", directoryHint: .isDirectory)
        #expect(Self.opener(textEdit: Self.textEdit, calls).show(folder) == .finder(folder))
        #expect(calls.opened.withLock { $0 }.isEmpty)
    }

    @Test func theTargetPrefersThePreviousCrashThenTheNewestLog() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "crash-log-opener-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        let reports = root.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        // The directory listing returns resolved paths (/private/var for
        // /var), so the checks compare resolved paths.
        func target(_ previous: URL? = nil, _ report: URL? = nil) -> String {
            CrashLogOpener.target(previousSystemLog: previous, previousReport: report, reportDirectory: reports,
                                  systemLogs: system, executable: "cmux").resolvingSymlinksInPath().path
        }
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        // Nothing yet: the report folder.
        #expect(target() == path(reports))
        // cmux's own newest report.
        let own = reports.appending(path: "app-1.json")
        try Data("{}".utf8).write(to: own)
        #expect(target() == path(own))
        // A macOS report of this executable wins over cmux's report; other
        // executables' reports never count.
        let older = system.appending(path: "cmux-2026-10-04-055634.ips")
        let newer = system.appending(path: "cmux-2026-10-04-055814.ips")
        let other = system.appending(path: "cmux2-gpui-2026-10-04-060000.ips")
        for (index, file) in [older, newer, other].enumerated() {
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                                                  ofItemAtPath: file.path)
        }
        #expect(target() == path(newer))
        // The previous run's crash wins over everything.
        #expect(target(older, own) == path(older))
        #expect(target(nil, own) == path(own))
    }

    @Test func everySurfaceOffersTheAction() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "help.showCrashLogs" })
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.surfaces.contains(.menu))
        #expect(descriptor.mainMenu == .help)
        // `cmux settings show-crash-logs` is a CLI verb (not only
        // `cmux action run help.showCrashLogs`); agents do not get it as an
        // MCP tool (it opens an app window on the user's desktop).
        #expect(descriptor.cliName == "settings show-crash-logs")
        #expect(descriptor.surfacePlan.cli == .offered)
        #expect(descriptor.surfacePlan.mcpExemption == .systemChange)
    }
}
