import Foundation
import Testing
import CmuxSettings
@testable import CmuxBrowser

@Suite
@MainActor
struct BrowserExternalAppOpenerTests {
    @Test
    func configuredHTTPURLUsesResolvedApplication() {
        let defaults = makeDefaults()
        defaults.set("  com.example.Browser  ", forKey: BrowserExternalApplicationSettings.userDefaultsKey)
        let url = URL(string: "https://example.com")!
        let applicationURL = URL(fileURLWithPath: "/Applications/Browser.app")
        var opened: (URL, URL, Bool)?

        let opener = BrowserExternalAppOpener(
            defaults: defaults,
            openWithApplication: { url, application, activates in
                opened = (url, application, activates)
                return true
            },
            resolveApplication: { identifier in
                #expect(identifier == "com.example.Browser")
                return applicationURL
            },
            openWithSystemDefault: { _, _ in
                Issue.record("configured URL should not use the system fallback")
                return false
            }
        )

        #expect(opener.open(url))
        #expect(opened?.0 == url)
        #expect(opened?.1 == applicationURL)
        #expect(opened?.2 == true)
    }

    @Test
    func emptyOrUnresolvedApplicationUsesSystemDefault() {
        let defaults = makeDefaults()
        let url = URL(string: "https://example.com")!
        var fallbackActivates: Bool?
        let opener = BrowserExternalAppOpener(
            defaults: defaults,
            openWithApplication: { _, _, _ in
                Issue.record("unresolved URL should not use the configured opener")
                return false
            },
            resolveApplication: { _ in nil },
            openWithSystemDefault: { openedURL, activates in
                #expect(openedURL == url)
                fallbackActivates = activates
                return true
            }
        )

        #expect(opener.open(url, activates: false))
        #expect(fallbackActivates == false)
    }

    @Test
    func nonWebURLAlwaysUsesSystemDefault() {
        let defaults = makeDefaults()
        defaults.set("com.example.Browser", forKey: BrowserExternalApplicationSettings.userDefaultsKey)
        let url = URL(string: "mailto:test@example.com")!
        var fallbackURL: URL?
        let opener = BrowserExternalAppOpener(
            defaults: defaults,
            openWithApplication: { _, _, _ in
                Issue.record("non-web URL should not use the configured browser")
                return false
            },
            resolveApplication: { _ in
                Issue.record("non-web URL should not resolve a browser")
                return nil
            },
            openWithSystemDefault: { openedURL, _ in
                fallbackURL = openedURL
                return true
            }
        )

        #expect(opener.open(url))
        #expect(fallbackURL == url)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "BrowserExternalAppOpenerTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}
