import CmuxNextControl
import CmuxNextDesign
import Testing

/// The in-tree pages switch in the environment (`CMUX_IN_TREE_PAGES=1|0`, for benches and harnesses) reaches the
/// launch latch: `main` strips inherited cmux variables first (`LaunchIdentity.stripInheritedEnvironment`), and the
/// strip took every `CMUX*` key, this one too. So a bench's IN launch came up with in-tree pages off (the speed A/B
/// at e67776ff on cmux19: `asked 1, in_tree off`), and only the `in-tree-pages` tag prefix ever turned them on.
struct InTreePagesLaunchSwitchTests {
    @Test func theSwitchSurvivesTheLaunchStrip() {
        for value in ["1", "0"] {
            let launch = [InTreePages.environmentKey: value]
            #expect(!LaunchIdentity.inheritedKeys(processEnvironment: launch, bundledEnvironment: [:])
                .contains(InTreePages.environmentKey), "the launch strip took \(InTreePages.environmentKey)=\(value)")
            #expect(InTreePages.decide(fileOverride: nil, tag: nil, environment: launch).1 == "environment")
        }
    }

    /// One that another cmux's terminal passed on is that cmux's, and goes, like every other launch switch.
    @Test func aSwitchAnotherCmuxSetGoes() {
        let foreign = [InTreePages.environmentKey: "1", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])
            .contains(InTreePages.environmentKey))
    }
}
