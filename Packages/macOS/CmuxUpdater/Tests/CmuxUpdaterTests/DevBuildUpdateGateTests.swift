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
}
