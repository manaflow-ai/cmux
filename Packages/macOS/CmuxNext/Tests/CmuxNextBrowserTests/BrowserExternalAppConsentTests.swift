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

    /// cmux's own link (cmux.com's GitHub install callback redirecting to `cmux://integration/complete` inside
    /// cmux's browser) is answered by the app with no "Open cmux?" prompt, gesture or not; other links still ask.
    @Test func ownLinksSkipThePrompt() throws {
        let suite = "BrowserExternalAppConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = BrowserExternalApps(defaults: defaults)
        var handled: [URL] = []
        apps.ownLinks = { url in
            guard url.scheme == "cmux", url.host == "integration" else { return false }
            handled.append(url)
            return true
        }
        let completion = try #require(URL(string: "cmux://integration/complete?state=a.b.c&code=x"))
        var asked = 0
        apps.open(completion, from: URL(string: "https://cmux.com/integrations/callback"), userGesture: false) { _, _, _ in asked += 1 }
        #expect(handled == [completion])
        #expect(asked == 0)
    }
}
