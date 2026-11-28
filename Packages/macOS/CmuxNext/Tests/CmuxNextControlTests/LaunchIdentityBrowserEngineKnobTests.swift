@testable import CmuxNextControl
import Testing

/// The browser engine's A/B switches (`CMUX_CEF_*`, CEFLayerHosting) set on the app's own launch survive the launch
/// strip, so a bench's `--app-env=CMUX_CEF_RESIZE_FENCE=0` reaches the engine (it did not: both arms of a fence A/B
/// joined fences); ones another cmux's terminal passed on are that cmux's, and go.
@Suite struct LaunchIdentityBrowserEngineKnobTests {
    @Test func engineSwitchesSurviveTheStripUnlessAnotherCmuxSetThem() {
        let own = ["CMUX_CEF_RESIZE_FENCE": "0", "CMUX_CEF_RESIZE_FENCE_MS": "16", "CMUX_CEF_DRAG_KEEP_ATTACHED": "1"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).isEmpty)
        var foreign = own
        foreign["CMUX_BUNDLE_ID"] = "com.cmuxterm.app.nightly"
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])).isSuperset(of: own.keys))
    }

    @Test func otherCmuxVariablesStillGo() {
        let own = ["CMUX_CEF_RESIZE_FENCE": "0", "CMUX_COMPLETE_DUMP": "1"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]) == ["CMUX_COMPLETE_DUMP"])
    }
}
