import CmuxCore
import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserEngineResolverTests {
    private let resolver = BrowserEngineResolver()

    @Test(arguments: [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.OperaGX",
    ])
    func automaticUsesChromiumForChromiumHandlers(_ bundleIdentifier: String) {
        #expect(resolver.resolve(
            preference: .automatic,
            defaultHandlerBundleIdentifiers: [bundleIdentifier]
        ) == .chromium)
    }

    @Test(arguments: [
        "com.apple.Safari",
        "org.mozilla.firefox",
        "app.zen-browser.zen",
        "com.example.UnknownBrowser",
        "",
    ])
    func automaticUsesWebKitForSafariAndUnknownHandlers(_ bundleIdentifier: String) {
        #expect(resolver.resolve(
            preference: .automatic,
            defaultHandlerBundleIdentifiers: [bundleIdentifier]
        ) == .webKit)
    }

    @Test func explicitPreferenceOverridesDefaultHandler() {
        #expect(resolver.resolve(
            preference: .webKit,
            defaultHandlerBundleIdentifiers: ["com.google.Chrome"]
        ) == .webKit)
        #expect(resolver.resolve(
            preference: .chromium,
            defaultHandlerBundleIdentifiers: ["com.apple.Safari"]
        ) == .chromium)
    }

    @Test func automaticConsidersBothHTTPSAndHTTPHandlers() {
        #expect(resolver.resolve(
            preference: .automatic,
            defaultHandlerBundleIdentifiers: ["com.example.UnknownBrowser", "com.brave.Browser"]
        ) == .chromium)
    }
}
