import CmuxSettings
import Foundation
import Testing

struct BrowserExternalURLPolicyTests {
    @Test(arguments: [
        ("example.com", "https://example.com/", true),
        ("example.com", "https://EXAMPLE.COM/", true),
        (".*example\\.com.*", "https://example.com/", true),
        ("*example.*", "https://example.com/", true),
        ("https://example\\.com/.*", "https://example.com/path", true),
        ("*example.com*", "https://sub.example.com/path", true),
        ("http*://example.com/*", "https://example.com/path", true),
        ("http*://example.com/*", "http://example.com/path", true),
        ("https://example.com/?ath", "https://example.com/path", true),
        ("foo?bar", "https://example.com/fooxbar", true),
        ("https://example.com/foo?bar+baz", "https://example.com/fooXbar+baz", true),
        ("https://example\\.com/foo?bar+baz", "https://example.com/fooXbar+baz", true),
        ("foo+bar", "https://example.com/foo+bar", true),
        ("path(test)", "https://example.com/path(test)", true),
        ("example.com/(foo|bar)", "https://example.com/foo", true),
        ("example.com/[0-9]+", "https://example.com/42", true),
        ("re:https?://example\\.com/.*", "https://example.com/path", true),
        ("example.com", "https://other.test/", false),
    ])
    func matchesSupportedRuleForms(rule: String, urlString: String, expected: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(BrowserExternalURLPolicy(patterns: [rule]).matches(url) == expected)
    }

    @Test func explicitRegexAndInvalidEntriesAreHandledIndependently() throws {
        let policy = BrowserExternalURLPolicy(patterns: [
            "re:(",
            "example.com",
        ])

        #expect(policy.matches(try #require(URL(string: "https://example.com/path"))))
        #expect(!policy.matches(try #require(URL(string: "https://other.test/path"))))
    }

    @Test func stringAndArrayDefaultsValuesResolveToTheSameRules() throws {
        let suiteName = "BrowserExternalURLPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ".*example\\.com.*\n# ignored\nother.test",
            forKey: BrowserExternalURLPolicy.userDefaultsKey
        )
        let stringPolicy = BrowserExternalURLPolicy(defaults: defaults)

        defaults.set(
            [".*example\\.com.*", "# ignored", "other.test"],
            forKey: BrowserExternalURLPolicy.userDefaultsKey
        )
        let arrayPolicy = BrowserExternalURLPolicy(defaults: defaults)

        #expect(arrayPolicy == stringPolicy)
        #expect(arrayPolicy.matches(try #require(URL(string: "https://example.com"))))
        #expect(arrayPolicy.matches(try #require(URL(string: "https://other.test"))))
    }

    @Test func settingsStoreMigratesLegacyArrayForTheEditor() async throws {
        let suiteName = "BrowserExternalURLPolicyTests.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [" example.com ", "# ignored", "other.test"],
            forKey: BrowserExternalURLPolicy.userDefaultsKey
        )

        let store = UserDefaultsSettingsStore(defaults: defaults)
        let key = SettingCatalog().browser.urlsToAlwaysOpenExternally
        #expect(await store.value(for: key) == "example.com\nother.test")
        #expect(defaults.object(forKey: key.userDefaultsKey) as? String == "example.com\nother.test")
    }
}
