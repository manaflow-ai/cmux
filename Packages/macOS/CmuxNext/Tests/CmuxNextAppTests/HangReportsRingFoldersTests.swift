@testable import CmuxNextApp
import CmuxNextHangReports
import Foundation
import Testing

/// Hang reports and the crash forwarder read the Rust processes' black boxes from one folder list:
/// the daemon's key-flow folder is in it only while the app's knob passes one on.
@MainActor @Suite struct HangReportsRingFoldersTests {
    @Test func theKeyFlowFolderJoinsOnlyWithTheKnob() {
        let bundleID = "com.cmuxterm.app.next.test"
        let plain = HangReportsController.ringFolders(bundleID: bundleID, environment: [:])
        let flows = HangReportsController.ringFolders(bundleID: bundleID,
                                                      environment: ["CMUX_NEXT_TRACE_FLOWS": "/tmp/cmux-flows-test"])
        #expect(flows.directories == plain.directories + [URL(filePath: "/tmp/cmux-flows-test", directoryHint: .isDirectory)])
        #expect(flows.holderSockets == plain.holderSockets)
        #expect(plain.holderSockets == HangReportFieldSources.RingFolders.holderSocketDirectory())
        #expect(HangReportsController.ringFolders(bundleID: bundleID, environment: ["CMUX_TRACE_FLOWS": "/tmp/x"]) == plain,
                "the daemon's own name is stripped from the app; only the CMUX_NEXT_ knob counts")
    }
}
