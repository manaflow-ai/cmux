import Testing
@testable import CmuxUpdater

/// Verifies the DEV/staging bundle-id gate that keeps tagged local builds off the public
/// Sparkle release train (https://github.com/manaflow-ai/cmux/issues/6292).
@Suite struct DevBuildUpdateGateTests {
    @Test func publicReleaseBundleIsNotDevLike() {
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app"))
    }

    @Test func baseDebugBundleIsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug"))
    }

    @Test func taggedDebugBundleIsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug.issue-6292"))
    }

    @Test func baseStagingBundleIsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging"))
    }

    @Test func taggedStagingBundleIsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging.some-feature"))
    }

    @Test func nilBundleIsNotDevLike() {
        #expect(!UpdateController.isDevLikeBundleIdentifier(nil))
    }

    @Test func unrelatedBundlePrefixIsNotDevLike() {
        // Guard against a too-loose prefix match: a different app whose id merely starts with
        // the public id must not be treated as a dev build.
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debugger"))
    }

    // MARK: - shouldSuppressPublicUpdates (the effective gate the updater applies)

    @Test func publicReleaseIsNeverSuppressed() {
        #expect(!UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app", environment: [:]))
        // Even with a test harness present, the public build still runs the real update train.
        #expect(!UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app", environment: ["CMUX_UI_TEST_MODE": "1"]))
    }

    @Test func devBuildIsSuppressedOutsideHarness() {
        #expect(UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app.debug.issue-6292", environment: [:]))
        #expect(UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app.staging", environment: [:]))
    }

    @Test func devBuildIsNotSuppressedUnderUITestHarness() {
        // UpdatePillUITests run on the debug bundle and drive the update UI via CMUX_UI_TEST_*
        // injection; suppression must yield to the harness so those tests still work.
        #expect(!UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_UI_TEST_MODE": "1", "CMUX_UI_TEST_UPDATE_STATE": "available"]))
    }

    @Test func devBuildIsNotSuppressedUnderXCTestHarness() {
        #expect(!UpdateController.shouldSuppressPublicUpdates(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    @Test func harnessDetectionIgnoresBlankXCTestValues() {
        #expect(!UpdateController.isUpdateTestHarnessActive(
            environment: ["XCTestConfigurationFilePath": "   "]))
        #expect(UpdateController.isUpdateTestHarnessActive(
            environment: ["CMUX_UI_TEST_FEED_URL": "https://cmux.test/appcast.xml"]))
    }
}
