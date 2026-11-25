@testable import CmuxNextBrowser
import Foundation
import Testing

@MainActor
struct BrowserExternalAppConsentTests {
    @Test func firstClickAndRememberedConsent() throws {
        let suite = "BrowserExternalAppConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = BrowserExternalApps(defaults: defaults)
        let site = "https://example.test"

        for scheme in ["slack", "zoommtg", "zoom", "mailto", "tel", "vscode", "custom"] {
            #expect(!apps.canOpenWithoutPrompt(scheme, for: site, engine: .cef, userGesture: true))
        }
        #expect(apps.canOpenWithoutPrompt("slack", for: site, engine: .webkit, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("custom", for: site, engine: .webkit, userGesture: true))

        defaults.set([site: ["slack"]], forKey: "CmuxNextBrowser.externalSchemes")
        #expect(apps.canOpenWithoutPrompt("slack", for: site, engine: .cef, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("slack", for: site, engine: .cef, userGesture: false))
        #expect(!apps.canOpenWithoutPrompt("slack", for: "https://elsewhere.test", engine: .cef, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("mailto", for: site, engine: .cef, userGesture: true))
    }

    /// GitHub's install redirect to this app's own link, reached in cmux's own browser (a non-gesture 302): the app
    /// finishes it in place, so the tab never asks to open cmux; any other app's link still asks.
    @Test func ownLinksFinishInPlaceWithoutAsking() throws {
        let suite = "BrowserExternalAppConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = BrowserExternalApps(defaults: defaults)
        var handled: [URL] = []
        apps.ownLinks = { url in
            guard url.scheme == "cmux-next-test", url.host == "integration" else { return false }
            handled.append(url)
            return true
        }
        var asked = 0
        let own = try #require(URL(string: "cmux-next-test://integration/complete?state=a.b.c&code=x"))
        apps.open(own, from: URL(string: "https://github.com/apps/cmux"), userGesture: false) { _, _, _ in asked += 1 }
        #expect(handled == [own])
        #expect(asked == 0)
        // Not the app's own link: the shared opener's usual path (it asks, or does nothing for a scheme no app opens).
        apps.open(try #require(URL(string: "mailto:someone@example.test")), from: nil, userGesture: false) { _, _, _ in asked += 1 }
        #expect(handled == [own])
    }
}
