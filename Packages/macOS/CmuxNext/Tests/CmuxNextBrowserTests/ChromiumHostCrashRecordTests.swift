#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A Chromium Host crash record keeps the last 20 lines of the host's log with no URL in them.
@Suite struct ChromiumHostCrashRecordTests {
    @Test(arguments: [
        ("[ERROR:navigation_request.cc(1)] https://bank.example/login?u=me failed", "[ERROR:navigation_request.cc(1)] <url> failed"),
        ("load \"file:///Users/me/secret.html\"", "load \"<url>"),
        ("frame data:text/html;base64,PGh0bWw+ blob:https://a.example/uuid", "frame <url> <url>"),
        ("javascript:alert(1) and about:blank and view-source:x", "<url> and <url> and <url>"),
        ("chrome-extension://abc/page.html", "<url>"),
        ("url=(https://a.example/x)", "url=(<url>"),
        // Not URLs: Chromium's log prefix, a word that ends in a scheme's name, a time.
        ("[1027/120000.123456:ERROR:gpu_process_host.cc(990)] GPU process exited", "[1027/120000.123456:ERROR:gpu_process_host.cc(990)] GPU process exited"),
        ("metadata: 3 entries at 12:30:01", "metadata: 3 entries at 12:30:01"),
    ])
    func everyURLIsReplaced(line: String, scrubbed: String) {
        #expect(ChromiumHostCrashRecord.scrubbed(line[...]) == scrubbed)
    }

    @Test func aLongLineIsCut() {
        let line = String(repeating: "x", count: 1000)
        let kept = ChromiumHostCrashRecord.scrubbed(line[...])
        #expect(kept.count == ChromiumHostCrashRecord.lineLimit)
        #expect(kept.hasSuffix("…"))
    }

    @Test func theTailIsTheLast20NonBlankLines() {
        let log = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n\n  \n"
        let tail = ChromiumHostCrashRecord.logTail(Data(log.utf8), startsMidLine: false)
        #expect(tail == (21...40).map { "line \($0)" })
    }

    @Test func aReadFromTheMiddleLeavesOutTheCutFirstLine() {
        let tail = ChromiumHostCrashRecord.logTail(Data("ttps://cut.example/half\nline 2\r\nline 3".utf8), startsMidLine: true)
        #expect(tail == ["line 2", "line 3"])
    }

    @Test func theReaderReadsOnlyTheLogsEnd() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "chromium-host-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let filler = String(repeating: "f", count: 100)
        let log = (1...1000).map { "\($0) \(filler)" }.joined(separator: "\n") + "\n"
        try Data(log.utf8).write(to: file)
        let tail = ChromiumHostCrashRecord.logTail(of: file)
        #expect(tail == (981...1000).map { "\($0) \(filler)" })
        #expect(ChromiumHostCrashRecord.logTail(of: file.appendingPathExtension("missing")).isEmpty)
    }

    @Test func theSignalHasItsName() {
        let record = ChromiumHostCrashRecord(date: Date(), pid: 1, signal: SIGTRAP, exitCode: nil, reason: .crashed, startFailure: nil,
                                             saidHello: true, cefVersion: nil, forkAPI: nil, logTail: [])
        #expect(record.signalName == "SIGTRAP")
    }
}
#endif
