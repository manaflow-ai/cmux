import Testing

@testable import CmuxMobileShellModel

/// The distribution-channel classification that gates internal build-lane
/// vocabulary (DEV, BETA, INTERNAL, tag grants, TestFlight) out of public UI.
/// App Review rejected the App Store app under Guideline 2.2 for that
/// vocabulary in production copy, so the public channels must classify as
/// neutral and unknown Release bundles must fail closed to neutral.
struct MobileBuildTypeTests {
    @Test func internalVocabularyStaysOnTeamChannels() {
        #expect(MobileBuildType.dev.usesInternalBuildVocabulary)
        #expect(MobileBuildType.beta.usesInternalBuildVocabulary)
        #expect(MobileBuildType.internal.usesInternalBuildVocabulary)
        #expect(!MobileBuildType.demo.usesInternalBuildVocabulary)
        #expect(!MobileBuildType.prod.usesInternalBuildVocabulary)
    }

    @Test func appStoreBundleResolvesToProd() {
        let resolved = MobileBuildType.resolve(
            isDebugBuild: false,
            bundleIdentifier: "com.cmux.app"
        )
        #expect(resolved == .prod)
        #expect(!resolved.usesInternalBuildVocabulary)
    }

    @Test func unknownReleaseBundleFailsClosedToNeutralVocabulary() {
        let resolved = MobileBuildType.resolve(
            isDebugBuild: false,
            bundleIdentifier: "com.example.sideload"
        )
        #expect(resolved == .prod)
        #expect(!resolved.usesInternalBuildVocabulary)
    }

    @Test func currentUnderTestsIsADevBuild() {
        // Tests compile DEBUG, so `current()` short-circuits to `.dev` before
        // consulting the bundle identifier. This documents why channel-gated
        // copy is asserted through explicit build-type injection.
        #expect(MobileBuildType.current(bundleIdentifier: "com.cmux.app") == .dev)
    }
}
