import Foundation
import Testing
@testable import CmuxNextDaemon

/// The version handoff's rule: which running owner is another build than the bundled binary.
/// Pure: no daemon runs.
struct DaemonVersionDecisionTests {
    private func decide(_ running: DaemonBuildStamp, _ bundled: DaemonBuildStamp?) -> DaemonVersionDecision {
        DaemonLauncher.versionDecision(running: running, bundled: bundled)
    }

    /// Two packaged builds: `build_id` is the stamped commit.
    @Test func stampedBuildsCompareByBuild() {
        let abc = DaemonBuildStamp(commit: "abc1234", id: "abc1234")
        let def = DaemonBuildStamp(commit: "def5678", id: "def5678")
        #expect(decide(abc, abc) == .keep("same build"))
        #expect(decide(abc, def) == .restart(running: "abc1234", bundled: "def5678"))
    }

    /// An owner older than `daemon-build-v1` reports no `build_id`: the stamped commits decide.
    @Test func anOwnerWithoutBuildIDComparesCommits() {
        let old = DaemonBuildStamp(commit: "abc1234", id: nil)
        #expect(decide(old, DaemonBuildStamp(commit: "abc1234", id: "abc1234")) == .keep("same build"))
        #expect(decide(old, DaemonBuildStamp(commit: "def5678", id: "def5678"))
            == .restart(running: "abc1234", bundled: "def5678"))
    }

    /// Two unstamped builds of one commit with different uncommitted edits: no `build_commit`, and
    /// `build_id` carries the dirty hash. The owner runs the other edits, so it is handed off. On
    /// the code before this fix the null commit kept it with no notice ("running build unknown").
    @Test func aDirtyBuildOfTheSameCommitIsHandedOff() {
        let running = DaemonBuildStamp(commit: nil, id: "abc1234-dirty.aaaa")
        let bundled = DaemonBuildStamp(commit: nil, id: "abc1234-dirty.bbbb")
        #expect(decide(running, bundled) == .restart(running: "abc1234-dirty.aaaa", bundled: "abc1234-dirty.bbbb"))
        #expect(decide(running, running) == .keep("same build"))
    }

    /// One commit stamped on both, but the identities differ: the identity decides, not the commit.
    @Test func theBuildIDDecidesOverTheCommit() {
        let running = DaemonBuildStamp(commit: "abc1234", id: "abc1234-dirty.aaaa")
        let bundled = DaemonBuildStamp(commit: "abc1234", id: "abc1234-dirty.bbbb")
        #expect(decide(running, bundled) == .restart(running: "abc1234-dirty.aaaa", bundled: "abc1234-dirty.bbbb"))
    }

    /// When nothing can be compared the owner is kept, and the reason says which side is unknown.
    @Test func anUnknownBuildIsKeptWithItsReason() {
        let known = DaemonBuildStamp(commit: "abc1234", id: "abc1234")
        #expect(decide(DaemonBuildStamp(commit: nil, id: nil), known) == .keep("running build unknown"))
        #expect(decide(known, nil) == .keep("bundled build unknown"))
        #expect(decide(known, DaemonBuildStamp(commit: nil, id: nil)) == .keep("bundled build unknown"))
    }

    /// `cmux --version --json` and `identify` give the same two fields.
    @Test func theStampReadsTheVersionJSONAndIdentify() throws {
        let json = Data(#"{"app":"cmux-tui","build_identity":"abc1234-dirty.aaaa","build_commit":null}"#.utf8)
        #expect(DaemonBuildStamp(versionJSON: json) == DaemonBuildStamp(commit: nil, id: "abc1234-dirty.aaaa"))
        #expect(DaemonBuildStamp(versionJSON: Data("cmux 0.1.0".utf8)) == nil)
        let identity = DaemonIdentity(buildCommit: "", buildID: "abc1234", generation: DaemonGeneration(rawValue: "stamp-test"))
        #expect(DaemonBuildStamp(identity: identity) == DaemonBuildStamp(commit: nil, id: "abc1234"))
    }
}
