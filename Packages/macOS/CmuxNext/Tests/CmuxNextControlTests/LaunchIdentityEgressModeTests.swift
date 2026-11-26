import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// NIGHTLY, DEV and staging builds run the egress gate in enforce mode (docs/privacy.md, cmux-egress): the launch
/// sets `CMUX_EGRESS=enforce` for every Rust child when nothing set it, and a stable or rc build keeps the gate's
/// own default.
@Suite struct LaunchIdentityEgressModeTests {
    static func mode(_ bundleID: String) -> String? {
        LaunchIdentity.childEgressMode(BuildIdentity(bundleID: bundleID, bundledTag: nil))
    }

    @Test func nightlyAndDevEnforce() {
        for bundle in ["com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.debug",
                       "com.cmuxterm.app.debug.my-tag"] {
            #expect(Self.mode(bundle) == "enforce", "\(bundle)")
        }
    }

    @Test func stableKeepsTheGateDefault() {
        #expect(Self.mode("com.cmuxterm.app") == nil)
    }

    /// A value the launch passed (`--env CMUX_EGRESS=log`) survives the strip; another cmux's value does not.
    @Test func anExplicitModeSurvivesAndAnInheritedOneIsStripped() {
        let own = ["CMUX_EGRESS": "log"]
        #expect(!LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).contains("CMUX_EGRESS"))
        let inherited = ["CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.other", "CMUX_EGRESS": "off"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: inherited, bundledEnvironment: [:]).contains("CMUX_EGRESS"))
    }
}
