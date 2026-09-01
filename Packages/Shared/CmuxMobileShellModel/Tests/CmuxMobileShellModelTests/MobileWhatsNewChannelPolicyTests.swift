import Testing

@testable import CmuxMobileShellModel

/// The channel gate that keeps What's New announcement surfaces off the
/// official App Store app (Guideline 2.2, submission 591a59e6) unless a
/// remote entry explicitly opts into the official channel.
struct MobileWhatsNewChannelPolicyTests {
    @Test func undeclaredChannelsDefaultToTeamLanesOnly() {
        #expect(MobileWhatsNewChannelPolicy.isVisible(channelTokens: nil, buildType: .dev))
        #expect(MobileWhatsNewChannelPolicy.isVisible(channelTokens: nil, buildType: .beta))
        #expect(MobileWhatsNewChannelPolicy.isVisible(channelTokens: nil, buildType: .internal))
        #expect(!MobileWhatsNewChannelPolicy.isVisible(channelTokens: nil, buildType: .demo))
        #expect(!MobileWhatsNewChannelPolicy.isVisible(channelTokens: nil, buildType: .prod))
    }

    @Test func explicitProdTokenOptsIntoTheOfficialApp() {
        #expect(MobileWhatsNewChannelPolicy.isVisible(
            channelTokens: ["beta", "internal", "dev", "prod"],
            buildType: .prod
        ))
        #expect(MobileWhatsNewChannelPolicy.isVisible(
            channelTokens: ["prod"],
            buildType: .prod
        ))
    }

    @Test func explicitListReplacesTheDefaultEntirely() {
        // Declaring channels narrows as well as widens: a prod-only entry is
        // hidden from team lanes.
        #expect(!MobileWhatsNewChannelPolicy.isVisible(
            channelTokens: ["prod"],
            buildType: .beta
        ))
        #expect(!MobileWhatsNewChannelPolicy.isVisible(
            channelTokens: ["prod"],
            buildType: .dev
        ))
    }

    @Test func emptyAndUnknownTokensFailClosed() {
        for buildType in [MobileBuildType.dev, .beta, .internal, .demo, .prod] {
            #expect(!MobileWhatsNewChannelPolicy.isVisible(
                channelTokens: [],
                buildType: buildType
            ))
        }
        // A typo ("official" is not a token; the canonical token is "prod")
        // hides rather than shows.
        #expect(!MobileWhatsNewChannelPolicy.isVisible(
            channelTokens: ["official"],
            buildType: .prod
        ))
    }

    @Test func channelTokensMatchBuildTypeTokensExactly() {
        // The remote catalog validates channels against this exact set; a
        // rename on either side must fail here first.
        #expect(MobileBuildType.dev.token == "dev")
        #expect(MobileBuildType.beta.token == "beta")
        #expect(MobileBuildType.internal.token == "internal")
        #expect(MobileBuildType.demo.token == "demo")
        #expect(MobileBuildType.prod.token == "prod")
    }
}
