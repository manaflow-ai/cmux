@testable import CmuxMobileShell
import Foundation
import Testing

/// A plain SSH shell has no server-side query for its folder, so the Files
/// chip learns it from the OSC 7 reports the shell prints (the same way a
/// terminal does). These pin the stream reader and the provider wiring.
struct MobileSSHWorkingDirectoryReportTests {
    private func consume(_ text: String, chunkSize: Int? = nil) -> String? {
        var report = MobileSSHWorkingDirectoryReport()
        let bytes = Data(text.utf8)
        guard let chunkSize else {
            report.consume(bytes)
            return report.directory
        }
        var index = 0
        while index < bytes.count {
            report.consume(bytes.subdata(in: index..<min(bytes.count, index + chunkSize)))
            index += chunkSize
        }
        return report.directory
    }

    @Test func belTerminatedFileURLIsTheDirectory() {
        #expect(consume("\u{1B}]7;file://box/home/me/src\u{07}me@box:~/src$ ") == "/home/me/src")
    }

    @Test func stringTerminatorAndPercentEncodingAreHandled() {
        #expect(consume("\u{1B}]7;file://box/tmp/My%20Project\u{1B}\\$ ") == "/tmp/My Project")
    }

    @Test func theNewestReportWins() {
        let stream = "\u{1B}]7;file://h/a\u{07}$ cd b\r\n\u{1B}]7;file://h/a/b\u{07}$ "
        #expect(consume(stream) == "/a/b")
    }

    @Test(arguments: [1, 2, 3, 7])
    func aReportSplitAcrossChunksIsJoined(chunkSize: Int) {
        let stream = "out\u{1B}[1mbold\u{1B}[0m\u{1B}]0;title\u{07}\u{1B}]7;file://host/var/log\u{07}$ "
        #expect(consume(stream, chunkSize: chunkSize) == "/var/log")
    }

    @Test func otherOSCsAndPlainTextReportNothing() {
        #expect(consume("\u{1B}]0;file://h/not/cwd\u{07}\u{1B}]133;A\u{07}7;file://h/x plain text") == nil)
    }

    @Test func kittyShellCwdIsNotPercentDecoded() {
        #expect(consume("\u{1B}]7;kitty-shell-cwd://h/tmp/100%25\u{07}") == "/tmp/100%25")
    }

    @Test func malformedReportsAreIgnoredAndKeepThePreviousDirectory() {
        var report = MobileSSHWorkingDirectoryReport()
        report.consume(Data("\u{1B}]7;file://h/good\u{07}".utf8))
        report.consume(Data("\u{1B}]7;relative/path\u{07}\u{1B}]7;file://hostonly\u{07}".utf8))
        // Cancelled by CAN, then an overlong report.
        report.consume(Data("\u{1B}]7;file://h/cancelled\u{18}".utf8))
        let long = String(repeating: "x", count: MobileSSHWorkingDirectoryReport.maximumReportLength + 1)
        report.consume(Data("\u{1B}]7;file://h/\(long)\u{07}".utf8))
        #expect(report.directory == "/good")
    }

    @Test func consumeReturnsOnlyWhenAReportCompletes() {
        var report = MobileSSHWorkingDirectoryReport()
        #expect(report.consume(Data("\u{1B}]7;file://h/p".utf8)) == nil)
        #expect(report.consume(Data("art\u{07}".utf8)) == "/part")
        #expect(report.consume(Data("more output".utf8)) == nil)
        #expect(report.directory == "/part")
    }

    @MainActor @Test func plainShellReportsTheFolderItsOutputAnnounced() async throws {
        let provider = MobileSSHPlainProvider(connection: nil)
        let shell = try await provider.createWorkspace()
        let terminalID = shell.terminals[0].id
        #expect(await provider.reportedCurrentDirectory(terminalID: terminalID) == nil)

        provider.observeOutput(.output(Data("\u{1B}]7;file://h/srv/ap".utf8)), terminalID: terminalID)
        provider.observeOutput(.output(Data("p\u{07}$ ".utf8)), terminalID: terminalID)
        #expect(await provider.reportedCurrentDirectory(terminalID: terminalID) == "/srv/app")

        // Another shell's reports are its own.
        let other = try await provider.createWorkspace()
        #expect(await provider.reportedCurrentDirectory(terminalID: other.terminals[0].id) == nil)

        // The folder is forgotten when the shell ends.
        provider.observeOutput(.ended, terminalID: terminalID)
        #expect(await provider.reportedCurrentDirectory(terminalID: terminalID) == nil)
    }
}
