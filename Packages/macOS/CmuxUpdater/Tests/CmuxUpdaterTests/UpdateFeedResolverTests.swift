import Testing
@testable import CmuxUpdater

@Suite struct UpdateFeedResolverTests {
    @Test func missingInfoFeedURLUsesFallback() {
        let resolver = UpdateFeedResolver(fallbackFeedURL: "https://example.com/appcast.xml")
        let resolution = resolver.resolve(infoFeedURL: nil)
        #expect(resolution.url == "https://example.com/appcast.xml")
        #expect(resolution.usedFallback)
        #expect(!resolution.isNightly)
    }

    @Test func emptyInfoFeedURLUsesFallback() {
        let resolver = UpdateFeedResolver(fallbackFeedURL: "https://example.com/appcast.xml")
        let resolution = resolver.resolve(infoFeedURL: "")
        #expect(resolution.url == "https://example.com/appcast.xml")
        #expect(resolution.usedFallback)
    }

    @Test func stableInfoFeedURLIsUsedVerbatim() {
        let resolver = UpdateFeedResolver()
        let resolution = resolver.resolve(infoFeedURL: "https://example.com/stable/appcast.xml")
        #expect(resolution.url == "https://example.com/stable/appcast.xml")
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

    /// Stable stays universal: its feed URL is never rewritten per architecture.
    @Test func stableFeedIsNotRewrittenPerArchitecture() {
        let resolver = UpdateFeedResolver(hostArchitecture: .x86_64)
        #expect(resolver.resolve(infoFeedURL: "https://example.com/stable/appcast.xml").url
            == "https://example.com/stable/appcast.xml")
        #expect(resolver.resolve(infoFeedURL: nil).url == resolver.fallbackFeedURL)
    }
}
