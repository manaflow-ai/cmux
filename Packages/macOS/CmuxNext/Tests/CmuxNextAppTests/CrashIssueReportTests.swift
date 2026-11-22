import Foundation
import Testing
@testable import CmuxNextApp

/// The restart notice's Report button opens a prefilled GitHub issue (crash
/// program phase 2). It names the cause and carries no home folder path.
@Suite struct CrashIssueReportTests {
    static func run(signal: Int32? = nil, exception: RecordedException? = nil) -> PreviousRun {
        var run = PreviousRun(pid: 7, launched: Date(timeIntervalSince1970: 1_000), recovery: false, survived: true, signal: signal)
        run.exception = exception
        return run
    }

    @Test func anExceptionCrashNamesTheExceptionAndKeepsItsFramesWithoutTheHomePath() throws {
        let home = NSHomeDirectory()
        let exception = RecordedException(
            name: "NSRangeException", reason: "NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds",
            frames: ["0 CoreFoundation 0x1 __exceptionPreprocess", "1 cmux 0x2 TextLayout.attributed (\(home)/src/TextLayout.swift)"])
        let report = CrashIssueReport(previous: Self.run(signal: 6, exception: exception), version: "1.0 (42)",
                                      bundleID: "com.cmuxterm.app.nightly", osVersion: "26.1")
        #expect(report.title == "cmux-next crash: NSRangeException: NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds")
        #expect(report.body.contains("- Version: 1.0 (42)"))
        #expect(report.body.contains("TextLayout.attributed (~/src/TextLayout.swift)"))
        #expect(!report.body.contains(home))
        let url = try #require(report.url)
        #expect(url.absoluteString.hasPrefix("https://github.com/manaflow-ai/cmux/issues/new?title="))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "body" }?.value == report.body)
    }

    @Test func aSignalCrashNamesTheSignal() {
        let report = CrashIssueReport(previous: Self.run(signal: SIGSEGV), version: "1.0", bundleID: "b", osVersion: "26")
        #expect(report.title == "cmux-next crash: SIGSEGV")
        #expect(!report.body.contains("Exception frames"))
    }

    @Test func aCrashWithNoRecordSaysSo() {
        let report = CrashIssueReport(previous: Self.run(), version: "1.0", bundleID: "b", osVersion: "26")
        #expect(report.title == "cmux-next crash: unknown cause")
    }
}
