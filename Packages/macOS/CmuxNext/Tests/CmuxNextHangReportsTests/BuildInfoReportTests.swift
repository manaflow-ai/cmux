import CmuxNextHangReports
import Foundation
import Testing

/// Copy Version Info and Copy Debug Info (the command palette): the clipboard text names the
/// version, the build, the channel's bundle id and the commit; the debug text adds the system.
struct BuildInfoReportTests {
    private static let info: [String: Any] = [
        "CFBundleShortVersionString": "0.65.2", "CFBundleVersion": "3845050", "CMUXCommit": "539f78054aef",
    ]

    @Test func versionTextHasVersionBuildChannelAndCommit() {
        let report = BuildInfoReport(info: Self.info, bundleID: "com.cmuxterm.app.nightly")
        #expect(report.versionText() == "cmux 0.65.2 (3845050) com.cmuxterm.app.nightly\nCommit: 539f78054aef\n")
    }

    @Test func debugTextIsTheVersionTextThenTheSystem() {
        let report = BuildInfoReport(info: Self.info, bundleID: "com.cmuxterm.app.nightly",
                                     system: ["macOS 26.1 (Build 25B78)", "Hardware: arm64, Apple M4 Pro, 14 cores, 48 GB", "Language: en (system en-US)"])
        let text = report.debugText()
        #expect(text.hasPrefix(report.versionText()))
        #expect(text == """
        cmux 0.65.2 (3845050) com.cmuxterm.app.nightly
        Commit: 539f78054aef
        macOS 26.1 (Build 25B78)
        Hardware: arm64, Apple M4 Pro, 14 cores, 48 GB
        Language: en (system en-US)

        """)
        #expect(report.header == ["cmux 0.65.2 (3845050) com.cmuxterm.app.nightly", "macOS 26.1 (Build 25B78)",
                                  "Hardware: arm64, Apple M4 Pro, 14 cores, 48 GB", "Language: en (system en-US)"])
    }

    @Test func theRunningBuildsDebugTextNamesItsVersionAndBuildAndTheSystem() {
        let report = BuildInfoReport.current(logs: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Logs/cmux"))
        let text = report.debugText()
        #expect(text.hasPrefix("cmux \(report.version) (\(report.build)) "))
        #expect(text.contains("\nmacOS "))
        #expect(text.contains("\nHardware: "))
        #expect(text.contains("\nLogs: ~/Library/Logs/cmux\n"))
    }

    @Test func aBundleWithoutKeysSaysSoAndLeavesOutTheCommit() {
        let report = BuildInfoReport(info: ["CMUXCommit": "  "], bundleID: nil)
        #expect(report.versionText() == "cmux ? (?) ?\n")
    }

    @Test func theLogFolderNamesNoUser() {
        #expect(BuildInfoReport.abbreviatingHome("/Users/someone/Library/Logs/cmux", home: "/Users/someone") == "~/Library/Logs/cmux")
        #expect(BuildInfoReport.abbreviatingHome("/Users/someone2/x", home: "/Users/someone/") == "/Users/someone2/x")
        #expect(BuildInfoReport.abbreviatingHome("/tmp/x", home: "/Users/someone") == "/tmp/x")
    }
}
