import Testing
import CmuxBrowser

@Suite
struct BrowserEngineKindTests {
    @Test(arguments: [
        ("webkit", BrowserEngineKind.webkit),
        ("WebKit", .webkit),
        (" safari ", .webkit),
        ("chromium", .chromium),
        ("CEF", .chromium),
        ("chrome", .chromium),
    ])
    func parsesNamesAndAliases(value: String, expected: BrowserEngineKind) {
        #expect(BrowserEngineKind(requestValue: value) == expected)
    }

    @Test(arguments: [nil, "", "  ", "firefox", "gecko"] as [String?])
    func rejectsUnknownNames(value: String?) {
        #expect(BrowserEngineKind(requestValue: value) == nil)
    }

    @Test func rawValuesAreSettingValues() {
        #expect(BrowserEngineKind.allCases.map(\.rawValue) == ["webkit", "chromium"])
    }

    @Test func unavailableReasonCodesAreStable() {
        #expect(BrowserEngineUnavailableReason.notBundled.code == "notBundled")
        #expect(BrowserEngineUnavailableReason.startFailed("x").code == "startFailed")
        #expect(BrowserEngineUnavailableReason.startFailed("x").detail == "x")
        #expect(BrowserEngineUnavailableReason.shutDown.code == "shutDown")
        #expect(BrowserEngineUnavailableReason.shutDown.detail == nil)
    }
}
