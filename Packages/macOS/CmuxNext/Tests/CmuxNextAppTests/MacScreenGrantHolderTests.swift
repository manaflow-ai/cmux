import CmuxNextDesign
@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Screen sharing and computer use ask for, and System Settings lists, one app (Lawrence,
/// 2026-11-17: "ensure screen sharing + computer use uses same app for permissions"): a release,
/// NIGHTLY or RC build carries `cmux-screen-sharing` inside `cmux Computer Use.app`, and every
/// permission line names that app, the one whose switch the person turns on.
@MainActor @Suite
struct MacScreenGrantHolderTests {
    /// The guide's permission steps name the app whose switch the person turns on.
    @Test(arguments: CmuxRemoteSharingSetup.Step.allCases.filter { $0 != .overview })
    func theGuideNamesTheGrantHolder(_ step: CmuxRemoteSharingSetup.Step) {
        let spec = CmuxRemoteSharingSetup.spec(step, holder: "cmux Computer Use")
        #expect(spec.lines.contains { $0.contains("cmux Computer Use") }, "\(spec.lines)")
        if step == .screen || step == .screenCheck {
            #expect(spec.lines.allSatisfy { $0.contains("cmux Computer Use") }, "\(spec.lines)")
        }
    }

    /// Before the host answers, the copy names cmux Computer Use: never this app, which holds no grant.
    @Test func beforeTheHostAnswersTheCopyNamesTheHelper() {
        #expect(MacScreenGrantCopy.holder(nil) == "cmux Computer Use")
        #expect(MacScreenGrantCopy.holder("") == "cmux Computer Use")
        #expect(MacScreenGrantCopy.setupAllow(nil).contains("cmux Computer Use"))
        #expect(CmuxRemoteSharingSetup.spec(.screen).lines.allSatisfy { $0.contains("cmux Computer Use") })
        #expect(MacScreenGrantCopy.holder("cmux Computer Use (dev)") == "cmux Computer Use (dev)")
    }

    /// The running guide reads the holder from the share host after its grant check.
    @Test func theRunningGuideNamesTheHostsHolder() async throws {
        var setup = CmuxRemoteSharingSetup(host: MacScreenHubHost(share: MacScreenShareHost()))
        setup.refresh = { (false, false) }
        setup.enable = {}
        setup.holder = { "cmux Computer Use" }
        var shown: [[String]] = []
        let shared = try await setup.proceed(after: "continue") { spec in
            shown.append(spec.lines)
            return "cancel"
        }
        #expect(!shared)
        #expect(shown.count == 1)
        #expect(shown.first?.allSatisfy { $0.contains("cmux Computer Use") } == true, "\(shown)")
    }

    /// The Screen Recording rows name the helper, never "reopen cmux".
    @Test func theScreenRecordingRowsNameTheHelper() {
        for holder in ["cmux Computer Use", nil] {
            #expect(MacScreenGrantCopy.screenRecordingDetail(holder).contains("cmux Computer Use"))
            #expect(MacScreenGrantCopy.screenRecordingNeeded(holder).contains("cmux Computer Use"))
            #expect(!MacScreenGrantCopy.screenRecordingNeeded(holder).contains("reopen cmux"))
        }
    }
}
