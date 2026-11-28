@testable import CmuxNextControl
import Testing

/// `CMUX_DISABLE_AUTO_UPDATE=1` (cmux#50783) reaches `ManagedUpdatePolicy.live` after the launch strip, also when
/// another cmux's terminal started the launch: it only turns this process's updater off. Stripped, a fresh-home
/// capture of an older NIGHTLY installed the newest one mid-run and quit between steps ("ignored inherited").
@Suite struct LaunchIdentityDisableAutoUpdateTests {
    @Test func theSwitchSurvivesTheStrip() {
        let own = [LaunchIdentity.disableAutoUpdateKey: "1"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).isEmpty)
        let foreign = [LaunchIdentity.disableAutoUpdateKey: "1", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(!LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:]).contains(LaunchIdentity.disableAutoUpdateKey))
    }

    @Test func theNameIsTheOneTheUpdaterReads() {
        #expect(LaunchIdentity.disableAutoUpdateKey == "CMUX_DISABLE_AUTO_UPDATE")
    }
}
