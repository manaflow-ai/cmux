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
}
