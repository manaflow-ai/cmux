import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// A DEV build's files reach its children through its environment (``BuildStatePaths/environment``). Inherited from
/// another cmux's terminal they are that build's files, so a launch from there strips every one of them.
@Suite struct LaunchIdentityDevBuildStateTests {
    @Test func anotherBuildsFilesAreStripped() {
        let other = BuildStatePaths(build: BuildIdentity(bundleID: "com.cmuxterm.app.debug.other", bundledTag: nil),
                                    userHome: URL(fileURLWithPath: "/Users/me"),
                                    applicationSupport: URL(fileURLWithPath: "/Users/me/Library/Application Support"),
                                    caches: URL(fileURLWithPath: "/Users/me/Library/Caches"))
        let inherited = other.environment.merging(["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.other"]) { $1 }
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: inherited, bundledEnvironment: [:]))
        for key in BuildStatePaths.environmentKeys {
            #expect(stripped.contains(key), "\(key) from another build's terminal survived the launch")
        }
    }

    /// A person's own budget file, set in a shell that is no cmux's, is kept.
    @Test func aPersonsBudgetIsKept() {
        let stripped = LaunchIdentity.inheritedKeys(processEnvironment: ["ACPMUX_HOST_BUDGET": "/Users/me/b.json"], bundledEnvironment: [:])
        #expect(!stripped.contains("ACPMUX_HOST_BUDGET"))
    }
}
