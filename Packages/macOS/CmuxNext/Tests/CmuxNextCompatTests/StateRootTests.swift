import CmuxNextCompat
import Foundation
import Testing

/// `CMUX_NEXT_STATE_ROOT`: a launch's own state root. The app and the Rust CLI read the variable alike and name a
/// root's run the same, and a build under a root keeps its settings, configuration and state in it.
@Suite struct StateRootTests {
    static func root(_ value: String?) -> String? {
        NextSupport.stateRoot(environment: value.map { [NextSupport.stateRootKey: $0] } ?? [:])?.path
    }

    @Test func onlyAnAbsolutePathIsARoot() {
        #expect(Self.root(nil) == nil)
        #expect(Self.root("") == nil)
        #expect(Self.root("  ") == nil)
        #expect(Self.root("relative/run") == nil)
        #expect(Self.root("~/run") == nil)
        #expect(Self.root("/tmp/run-1/") == "/tmp/run-1")
        #expect(Self.root(" /tmp/run-1 \n") == "/tmp/run-1")
    }

    /// The same vector as cmux-cloud-environment's `run_segment_is_stable_and_matches_the_app`.
    @Test func runSegmentMatchesTheCLI() {
        #expect(NextSupport.runSegment(stateRoot: URL(fileURLWithPath: "/tmp/cmux-run-1", isDirectory: true)) == "run-8fde1965cd1ca6b3")
        #expect(NextSupport.runSegment(stateRoot: URL(fileURLWithPath: "/tmp/a")) != NextSupport.runSegment(stateRoot: URL(fileURLWithPath: "/tmp/b")))
    }

    /// NIGHTLY under a root keeps every path in the root's Application Support and Caches, sends its children there
    /// and keeps its Cloud secrets under the run's own Keychain service.
    @Test func aRootedBuildKeepsItsStateInTheRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/cmux-run-1", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let paths = BuildStatePaths(build: BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil), userHome: home,
                                    applicationSupport: root.appendingPathComponent("Library/Application Support", isDirectory: true),
                                    caches: root.appendingPathComponent("Library/Caches", isDirectory: true), stateRoot: root)
        #expect(!paths.isolatesSharedState)
        #expect(paths.ownsState)
        #expect(!paths.importsOtherBuildsPreferences)
        #expect(paths.cloudSecretsService == "cmux-cloud-secret.run-8fde1965cd1ca6b3")
        for (name, url) in paths.all {
            #expect(url.path.hasPrefix(root.path + "/Library/"), "\(name) is outside the root: \(url.path)")
        }
        #expect(Set(paths.environment.keys) == Set(BuildStatePaths.environmentKeys))
        #expect(BuildStatePaths.childEnvironmentKeys.contains(NextSupport.stateRootKey))
    }
}
