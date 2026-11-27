@testable import CmuxNextDaemonService
import CmuxNextDaemon
import Testing

/// The app's launch-time version check (`DaemonService.start`'s handoff step): which local owner
/// the app hands off to the bundled build. Pure: no daemon runs.
@Suite struct DaemonLaunchVersionCheckTests {
    private func identity(commit: String?, id: String?) -> DaemonIdentity {
        DaemonIdentity(buildCommit: commit, buildID: id, generation: DaemonGeneration(rawValue: "launch-check"))
    }

    /// An unstamped owner (no `build_commit`) of another build identity than the bundle is
    /// handed off. Before, the check returned at once on a null commit and kept it with no notice.
    @Test func anUnstampedOwnerOfAnotherBuildIsHandedOff() {
        let owner = identity(commit: nil, id: "abc1234-dirty.aaaa")
        let bundled = DaemonBuildStamp(commit: nil, id: "abc1234-dirty.bbbb")
        #expect(DaemonService.launchVersionCheck(identity: owner, bundled: bundled)
            == .restart(running: "abc1234-dirty.aaaa", bundled: "abc1234-dirty.bbbb"))
    }

    /// The same unstamped build is kept as the same build, not as an unknown one.
    @Test func anUnstampedOwnerOfTheBundledBuildIsKept() {
        let owner = identity(commit: nil, id: "abc1234-dirty.aaaa")
        #expect(DaemonService.launchVersionCheck(identity: owner, bundled: DaemonBuildStamp(identity: owner))
            == .keep("same build"))
    }

    /// No bundled answer keeps the owner, with that reason.
    @Test func noBundledAnswerKeepsTheOwnerWithItsReason() {
        let owner = identity(commit: "abc1234", id: "abc1234")
        #expect(DaemonService.launchVersionCheck(identity: owner, bundled: nil) == .keep("bundled build unknown"))
    }
}
