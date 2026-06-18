import Testing

@testable import CmuxMobileShellModel

/// Behavioral coverage for the pure Send Feedback routing decision and the
/// build-type / stamp formatting that every report carries.
struct MobileFeedbackRouteTests {
    // MARK: - Routing decision

    @Test func privilegedWhenManaflowConnectedAndHostSupportsSink() {
        #expect(
            MobileFeedbackRoute.resolve(
                email: "lawrence@manaflow.ai",
                hasActiveMacConnection: true,
                hostSupportsAgentSink: true
            ) == .privilegedAgent
        )
    }

    @Test func emailWhenManaflowButNotConnected() {
        #expect(
            MobileFeedbackRoute.resolve(
                email: "lawrence@manaflow.ai",
                hasActiveMacConnection: false,
                hostSupportsAgentSink: true
            ) == .email
        )
    }

    @Test func emailWhenConnectedButNotManaflow() {
        #expect(
            MobileFeedbackRoute.resolve(
                email: "someone@gmail.com",
                hasActiveMacConnection: true,
                hostSupportsAgentSink: true
            ) == .email
        )
    }

    @Test func emailWhenSignedOut() {
        #expect(
            MobileFeedbackRoute.resolve(
                email: nil,
                hasActiveMacConnection: true,
                hostSupportsAgentSink: true
            ) == .email
        )
    }

    @Test func emailWhenHostDoesNotAdvertiseSink() {
        // Version skew: a privileged user on an active connection to an older Mac
        // that does not expose `dogfood.feedback.submit` must fall back to email,
        // not take the agent path and fail with `method_not_found`.
        #expect(
            MobileFeedbackRoute.resolve(
                email: "lawrence@manaflow.ai",
                hasActiveMacConnection: true,
                hostSupportsAgentSink: false
            ) == .email
        )
    }

    @Test func manaflowMatchIsCaseAndWhitespaceInsensitive() {
        #expect(MobileFeedbackRoute.isManaflowEmail("  Lawrence@Manaflow.AI \n"))
        #expect(MobileFeedbackRoute.resolve(
            email: "  Lawrence@Manaflow.AI ",
            hasActiveMacConnection: true,
            hostSupportsAgentSink: true
        ) == .privilegedAgent)
    }

    @Test func lookalikeDomainsAreNotPrivileged() {
        #expect(!MobileFeedbackRoute.isManaflowEmail("evil@manaflow.ai.attacker.com"))
        #expect(!MobileFeedbackRoute.isManaflowEmail("evil@notmanaflow.ai")) // suffix guard alone would pass; ensure "@" anchor
        #expect(!MobileFeedbackRoute.isManaflowEmail("manaflow.ai"))
        #expect(!MobileFeedbackRoute.isManaflowEmail(""))
        #expect(!MobileFeedbackRoute.isManaflowEmail(nil))
    }

    @Test func subdomainImpersonationIsNotPrivileged() {
        // "x@manaflow.ai" is the only privileged shape; a subdomain is not.
        #expect(!MobileFeedbackRoute.isManaflowEmail("x@sub.manaflow.ai"))
    }

    // MARK: - Build-type derivation

    @Test func debugBuildIsAlwaysDev() {
        #expect(MobileBuildType.resolve(isDebugBuild: true, bundleIdentifier: "dev.cmux.app.beta") == .dev)
        #expect(MobileBuildType.resolve(isDebugBuild: true, bundleIdentifier: "dev.cmux.app") == .dev)
        #expect(MobileBuildType.resolve(isDebugBuild: true, bundleIdentifier: nil) == .dev)
    }

    @Test func releaseBetaBundleIsBeta() {
        #expect(MobileBuildType.resolve(isDebugBuild: false, bundleIdentifier: "dev.cmux.app.beta") == .beta)
    }

    @Test func releaseNonBetaBundleIsProd() {
        #expect(MobileBuildType.resolve(isDebugBuild: false, bundleIdentifier: "dev.cmux.app") == .prod)
        #expect(MobileBuildType.resolve(isDebugBuild: false, bundleIdentifier: nil) == .prod)
    }

    // MARK: - Stamp formatting

    @Test func versionDisplayCombinesVersionAndBuild() {
        let stamp = makeStamp(version: "0.64.13", build: "42")
        #expect(stamp.versionDisplay == "0.64.13 (42)")
    }

    @Test func versionDisplayFallsBackWhenFieldsMissing() {
        #expect(makeStamp(version: "0.64.13", build: "").versionDisplay == "0.64.13")
        #expect(makeStamp(version: "", build: "42").versionDisplay == "build 42")
        #expect(makeStamp(version: "", build: "").versionDisplay == "unknown")
    }

    @Test func subjectSuffixStampsBuildTypeAndVersion() {
        let beta = MobileFeedbackStamp(
            buildType: .beta, appVersion: "0.64.13", appBuild: "42",
            bundleIdentifier: "dev.cmux.app.beta", osVersion: "iOS 18.5", deviceModel: "iPhone16,2"
        )
        #expect(beta.subjectSuffix == "[Beta 0.64.13 (42)]")

        let prod = MobileFeedbackStamp(
            buildType: .prod, appVersion: "1.0.0", appBuild: "",
            bundleIdentifier: "dev.cmux.app", osVersion: "", deviceModel: ""
        )
        #expect(prod.subjectSuffix == "[Prod 1.0.0]")
    }

    @Test func agentBuildStampDropsEmptyFields() {
        let full = MobileFeedbackStamp(
            buildType: .beta, appVersion: "0.64.13", appBuild: "42",
            bundleIdentifier: "dev.cmux.app.beta", osVersion: "iOS 18.5", deviceModel: "iPhone16,2"
        )
        #expect(full.agentBuildStamp == "beta · 0.64.13 (42) · iOS 18.5 · iPhone16,2")

        let sparse = MobileFeedbackStamp(
            buildType: .dev, appVersion: "", appBuild: "",
            bundleIdentifier: "dev.cmux.ios", osVersion: "", deviceModel: ""
        )
        #expect(sparse.agentBuildStamp == "dev · unknown")
    }

    // MARK: - Helpers

    private func makeStamp(version: String, build: String) -> MobileFeedbackStamp {
        MobileFeedbackStamp(
            buildType: .beta,
            appVersion: version,
            appBuild: build,
            bundleIdentifier: "dev.cmux.app.beta",
            osVersion: "iOS 18.5",
            deviceModel: "iPhone16,2"
        )
    }
}
