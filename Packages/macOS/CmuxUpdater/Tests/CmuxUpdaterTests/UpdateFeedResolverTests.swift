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
}
