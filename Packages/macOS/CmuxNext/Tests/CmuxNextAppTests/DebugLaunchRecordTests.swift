#if DEBUG
@testable import CmuxNextApp
import Testing

/// `--record-launch DIR [--record-launch-seconds S]` records every window from the moment the
/// launch makes it, before the control socket is up (the never-blank first launch frame).
@MainActor
@Suite struct DebugLaunchRecordTests {
    @Test func theFolderAndSecondsComeFromTheArguments() {
        let request = DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--showcase", "--record-launch", "/tmp/rec", "--record-launch-seconds", "4"])
        #expect(request == DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--record-launch", "/tmp/rec", "--record-launch-seconds", "4"]))
        #expect(request?.dir == "/tmp/rec")
        #expect(request?.seconds == 4)
    }

    @Test func secondsDefaultToSixAndStayUnderTwelve() {
        #expect(DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--record-launch", "/tmp/rec"])?.seconds == 6)
        #expect(DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--record-launch", "/tmp/rec", "--record-launch-seconds", "60"])?.seconds == 12)
    }

    @Test func noFolderRecordsNothing() {
        #expect(DebugWindowRecord.LaunchRequest(arguments: ["cmux"]) == nil)
        #expect(DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--record-launch"]) == nil)
        #expect(DebugWindowRecord.LaunchRequest(arguments: ["cmux", "--record-launch", "--showcase"]) == nil)
    }
}
#endif
