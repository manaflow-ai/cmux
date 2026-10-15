import Testing
import CmuxBrowser

@Suite
struct BrowserEngineResolverTests {
    private let resolver = BrowserEngineResolver()

    private func availability(chromium: BrowserEngineAvailability) -> (BrowserEngineKind) -> BrowserEngineAvailability {
        { kind in kind == .chromium ? chromium : .available }
    }

    @Test func defaultSettingOpensWebKitWithoutFallback() {
        let result = resolver.resolve(
            requested: nil, inherited: nil, setting: .webkit,
            availability: availability(chromium: .unavailable(.notBundled))
        )
        #expect(result == .open(BrowserEngineChoice(engine: .webkit, source: .setting)))
    }

    @Test func chromiumSettingOpensChromiumWhenAvailable() {
        let result = resolver.resolve(
            requested: nil, inherited: nil, setting: .chromium,
            availability: availability(chromium: .available)
        )
        #expect(result == .open(BrowserEngineChoice(engine: .chromium, source: .setting)))
    }

    @Test func chromiumSettingFallsBackToWebKitWithReason() {
        let result = resolver.resolve(
            requested: nil, inherited: nil, setting: .chromium,
            availability: availability(chromium: .unavailable(.notBundled))
        )
        #expect(result == .open(BrowserEngineChoice(engine: .webkit, fallback: .notBundled, source: .setting)))
    }

    @Test func explicitChromiumIsRefusedWhenUnavailable() {
        let result = resolver.resolve(
            requested: .chromium, inherited: .webkit, setting: .webkit,
            availability: availability(chromium: .unavailable(.startFailed("boom")))
        )
        #expect(result == .refuse(.chromium, .startFailed("boom")))
    }

    @Test func explicitRequestWinsOverInheritedAndSetting() {
        let result = resolver.resolve(
            requested: .webkit, inherited: .chromium, setting: .chromium,
            availability: availability(chromium: .available)
        )
        #expect(result == .open(BrowserEngineChoice(engine: .webkit, source: .explicit)))
    }

    @Test func inheritedWinsOverSetting() {
        let result = resolver.resolve(
            requested: nil, inherited: .webkit, setting: .chromium,
            availability: availability(chromium: .available)
        )
        #expect(result == .open(BrowserEngineChoice(engine: .webkit, source: .inherited)))
    }

    @Test func inheritedChromiumFallsBackWithReason() {
        let result = resolver.resolve(
            requested: nil, inherited: .chromium, setting: .webkit,
            availability: availability(chromium: .unavailable(.shutDown))
        )
        #expect(result == .open(BrowserEngineChoice(engine: .webkit, fallback: .shutDown, source: .inherited)))
    }
}
