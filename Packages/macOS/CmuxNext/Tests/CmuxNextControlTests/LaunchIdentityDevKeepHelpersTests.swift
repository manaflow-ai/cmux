@testable import CmuxNextControl
import Testing

/// `CMUX_DEV_KEEP_HELPERS=1` keeps a tagged DEV build's helpers across a quit (DevBuildReaper). The
/// reaper reads the environment after the launch strip, which unset it, so the pair-e2e share leg's
/// quit still SIGTERMed the share host (runs 45918096680, 45931428739).
@Suite struct LaunchIdentityDevKeepHelpersTests {
    @Test func theVariableSurvivesTheStripUnlessAnotherCmuxSetIt() {
        let own = ["CMUX_DEV_KEEP_HELPERS": "1"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).isEmpty)
        let foreign = ["CMUX_DEV_KEEP_HELPERS": "1", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])).contains("CMUX_DEV_KEEP_HELPERS"))
    }
}
