@testable import CmuxNextControl
import Foundation
import Testing

/// Every Rust child of the app (the daemon, acpmux, the `cmux` CLI in its terminals) learns the build's cloud
/// space from `CMUX_BUILD_SPACE` (cmux-tui `cmux-build-space`): a tagged dev build's `dev:<slug>`, nothing for
/// nightly and stable. Without it a dev build's daemon wrote to nightly's conversations and automations.
@Suite struct LaunchIdentityBuildSpaceTests {
    static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    static func launch(_ bundleID: String, tag: String? = nil) -> LaunchIdentity {
        LaunchIdentity.resolve(bundleID: bundleID, bundledEnvironment: tag.map { ["CMUX_TAG": $0] } ?? [:],
                               processEnvironment: [:], isDebugBuild: true, home: home)
    }

    @Test func aTaggedDevBuildsChildrenGetItsBuildSpace() {
        #expect(Self.launch("com.cmuxterm.app.debug.my-tag").terminalEnvironment["CMUX_BUILD_SPACE"] == "dev:my-tag")
        #expect(Self.launch("com.cmuxterm.app.debug", tag: "My_Tag 2").terminalEnvironment["CMUX_BUILD_SPACE"]
            == "dev:my-tag-2")
    }

    @Test func nightlyAndStableChildrenGetNone() {
        for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next"] {
            #expect(Self.launch(bundle).terminalEnvironment["CMUX_BUILD_SPACE"] == nil, "\(bundle)")
        }
    }

    /// A DEV build with no usable tag never lets its children fall back to nightly's data: they get a value that is
    /// not a space, which every Rust cloud client refuses (cmux-tui `cmux-build-space`).
    @Test func anUntaggedDevBuildsChildrenGetARefusingValue() {
        #expect(Self.launch("com.cmuxterm.app.debug").terminalEnvironment["CMUX_BUILD_SPACE"] == "unusable")
        #expect(Self.launch("com.cmuxterm.app.debug", tag: "---").terminalEnvironment["CMUX_BUILD_SPACE"] == "unusable")
    }

    /// Another cmux's space, inherited from its terminal, is stripped at launch (it is replaced by this build's).
    @Test func anInheritedBuildSpaceIsStripped() {
        let inherited = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.other", "CMUX_BUILD_SPACE": "dev:other"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: inherited, bundledEnvironment: [:])
            .contains("CMUX_BUILD_SPACE"))
    }
}
