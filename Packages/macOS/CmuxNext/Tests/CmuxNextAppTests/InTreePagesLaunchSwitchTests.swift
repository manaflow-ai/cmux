import CmuxNextControl
import CmuxNextDesign
import Testing

/// The in-tree pages switch in the environment (`CMUX_IN_TREE_PAGES=1|0`, for benches and harnesses) reaches the
/// launch latch: `main` strips inherited cmux variables first (`LaunchIdentity.stripInheritedEnvironment`), and the
/// strip took every `CMUX*` key, this one too. So a bench's IN launch came up with in-tree pages off (the speed A/B
/// at e67776ff on cmux19: `asked 1, in_tree off`), and only the `in-tree-pages` tag prefix ever turned them on.
struct InTreePagesLaunchSwitchTests {
    @Test func theSwitchSurvivesTheLaunchStrip() {
        #expect(LaunchIdentity.inTreePagesKey == InTreePages.environmentKey)
        for value in ["1", "0"] {
            let launch = [InTreePages.environmentKey: value]
            #expect(!LaunchIdentity.inheritedKeys(processEnvironment: launch, bundledEnvironment: [:])
                .contains(InTreePages.environmentKey), "the launch strip took \(InTreePages.environmentKey)=\(value)")
            #expect(InTreePages.decide(fileOverride: nil, tag: nil, environment: launch).1 == "environment")
        }
    }

    /// The page resize fence's wait override (`CMUX_CEF_RESIZE_FENCE_MS`, `CEFLayerHosting.resizeFenceTimeoutOverrideMs`)
    /// reaches the app from a harness launch: the strip took it, so a harness's fence experiment ran with the override
    /// at 0 (other-Mac run on 9dfb6ffe: app.log "ignored inherited CMUX_CEF_RESIZE_FENCE_MS").
    @Test func theResizeFenceOverrideSurvivesTheLaunchStrip() {
        let launch = ["CMUX_CEF_RESIZE_FENCE_MS": "500"]
        #expect(!LaunchIdentity.inheritedKeys(processEnvironment: launch, bundledEnvironment: [:])
            .contains("CMUX_CEF_RESIZE_FENCE_MS"), "the launch strip took CMUX_CEF_RESIZE_FENCE_MS")
        let foreign = launch.merging(["CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]) { a, _ in a }
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])
            .contains("CMUX_CEF_RESIZE_FENCE_MS"), "another cmux's override reached this app")
    }

    /// One that another cmux's terminal passed on is that cmux's, and goes, like every other launch switch.
    @Test func aSwitchAnotherCmuxSetGoes() {
        let foreign = [InTreePages.environmentKey: "1", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])
            .contains(InTreePages.environmentKey))
    }
}
