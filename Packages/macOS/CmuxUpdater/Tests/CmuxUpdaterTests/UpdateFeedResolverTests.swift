import Testing
@testable import CmuxUpdater

@Suite struct UpdateFeedResolverTests {
    @Test func missingInfoFeedURLUsesFallback() {
        let resolver = UpdateFeedResolver(hostArchitecture: .arm64)
        let resolution = resolver.resolve(infoFeedURL: nil)
        #expect(resolution.url == "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-arm64.xml")
        #expect(resolution.usedFallback)
        #expect(!resolution.isNightly)
    }

    @Test func emptyInfoFeedURLUsesFallback() {
        let resolver = UpdateFeedResolver(hostArchitecture: .x86_64)
        let resolution = resolver.resolve(infoFeedURL: "")
        #expect(resolution.url == "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-x86_64.xml")
        #expect(resolution.usedFallback)
    }

    /// Stable ships thin DMGs too: the legacy feed every stable install reads resolves to the
    /// machine's own architecture feed, so a thin install never depends on the universal feed.
    @Test func stableInfoFeedURLResolvesToHostArchitectureFeed() {
        let resolver = UpdateFeedResolver(hostArchitecture: .arm64)
        let resolution = resolver.resolve(infoFeedURL: "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml")
        #expect(resolution.url == "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-arm64.xml")
        #expect(resolution.channel == .stable)
        #expect(!resolution.usedFallback)
        #expect(!resolution.isNightly)
    }

    @Test func nightlyInfoFeedURLIsClassifiedNightly() {
        let resolver = UpdateFeedResolver()
        let resolution = resolver.resolve(infoFeedURL: "https://example.com/nightly/appcast.xml")
        #expect(resolution.isNightly)
        #expect(!resolution.usedFallback)
    }

    /// Nightly ships one DMG per architecture, so the legacy universal feed name resolves to
    /// the feed for the machine's architecture. A universal or Rosetta-translated nightly
    /// migrates itself onto the native thin build this way.
    @Test func legacyNightlyFeedResolvesToHostArchitectureFeed() {
        let arm = UpdateFeedResolver(hostArchitecture: .arm64)
        #expect(arm.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast.xml").url
            == "https://files.cmux.com/nightly/appcast-arm64.xml")
        #expect(arm.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast-universal.xml").url
            == "https://files.cmux.com/nightly/appcast-arm64.xml")

        let intel = UpdateFeedResolver(hostArchitecture: .x86_64)
        #expect(intel.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast.xml").url
            == "https://files.cmux.com/nightly/appcast-x86_64.xml")
        #expect(intel.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast.xml").isNightly)
    }

    /// RC is on the same per-architecture layout as nightly: the CI-injected `appcast.xml`
    /// resolves to the host architecture's feed and is classified as the rc channel.
    @Test func rcFeedResolvesToHostArchitectureFeed() {
        let arm = UpdateFeedResolver(hostArchitecture: .arm64)
        let armResolution = arm.resolve(infoFeedURL: "https://files.cmux.com/rc/appcast.xml")
        #expect(armResolution.url == "https://files.cmux.com/rc/appcast-arm64.xml")
        #expect(armResolution.channel == .rc)
        #expect(!armResolution.isNightly)
        #expect(!armResolution.usedFallback)
        #expect(arm.resolve(infoFeedURL: "https://files.cmux.com/rc/appcast-universal.xml").url
            == "https://files.cmux.com/rc/appcast-arm64.xml")

        let intel = UpdateFeedResolver(hostArchitecture: .x86_64)
        #expect(intel.resolve(infoFeedURL: "https://files.cmux.com/rc/appcast.xml").url
            == "https://files.cmux.com/rc/appcast-x86_64.xml")
        #expect(intel.resolve(infoFeedURL: "https://files.cmux.com/rc/appcast-arm64.xml").url
            == "https://files.cmux.com/rc/appcast-arm64.xml")
    }

    @Test func channelsAreClassifiedFromTheFeedPath() {
        let resolver = UpdateFeedResolver(hostArchitecture: .arm64)
        #expect(resolver.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast.xml").channel == .nightly)
        #expect(resolver.resolve(infoFeedURL: "https://files.cmux.com/rc/appcast.xml").channel == .rc)
        #expect(resolver.resolve(infoFeedURL: "https://example.com/stable/appcast.xml").channel == .stable)
        #expect(resolver.resolve(infoFeedURL: nil).channel == .stable)
    }

    @Test func architectureSpecificNightlyFeedIsKept() {
        let intel = UpdateFeedResolver(hostArchitecture: .x86_64)
        #expect(intel.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast-arm64.xml").url
            == "https://files.cmux.com/nightly/appcast-arm64.xml")
        let arm = UpdateFeedResolver(hostArchitecture: .arm64)
        #expect(arm.resolve(infoFeedURL: "https://files.cmux.com/nightly/appcast-x86_64.xml").url
            == "https://files.cmux.com/nightly/appcast-x86_64.xml")
        #expect(arm.resolve(infoFeedURL: "https://files.cmux.com/nightly/feed.xml").url
            == "https://files.cmux.com/nightly/feed.xml")
    }

    /// An Intel stable install, and the files.cmux.com stable mirror, resolve the same way.
    @Test func stableFeedIsRewrittenPerArchitecture() {
        let resolver = UpdateFeedResolver(hostArchitecture: .x86_64)
        #expect(resolver.resolve(infoFeedURL: "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml").url
            == "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-x86_64.xml")
        #expect(resolver.resolve(infoFeedURL: "https://files.cmux.com/stable/appcast.xml").url
            == "https://files.cmux.com/stable/appcast-x86_64.xml")
        #expect(resolver.resolve(infoFeedURL: "https://files.cmux.com/stable/appcast-arm64.xml").url
            == "https://files.cmux.com/stable/appcast-arm64.xml")
    }

    /// Only cmux's own stable feeds publish per-architecture appcasts. A fork's or a
    /// self-hosted stable feed keeps the URL it was built with.
    @Test func customStableFeedIsKept() {
        let resolver = UpdateFeedResolver(hostArchitecture: .arm64)
        #expect(resolver.resolve(infoFeedURL: "https://example.com/custom/appcast.xml").url
            == "https://example.com/custom/appcast.xml")
        #expect(resolver.resolve(infoFeedURL: "https://example.com/stable/appcast.xml").url
            == "https://example.com/stable/appcast.xml")
        #expect(resolver.resolve(infoFeedURL: "https://github.com/someone/cmux/releases/latest/download/appcast.xml").url
            == "https://github.com/someone/cmux/releases/latest/download/appcast.xml")
        let fork = UpdateFeedResolver(fallbackFeedURL: "https://example.com/appcast.xml", hostArchitecture: .arm64)
        #expect(fork.resolve(infoFeedURL: nil).url == "https://example.com/appcast.xml")
    }
}
