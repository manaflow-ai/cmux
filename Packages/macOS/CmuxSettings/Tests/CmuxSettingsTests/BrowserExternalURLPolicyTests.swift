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
        ("foo\\?bar", "https://example.com/foo?bar", true),
        ("https://example.com/foo?bar+baz", "https://example.com/fooXbar+baz", true),
        ("https://example\\.com/foo?bar+baz", "https://example.com/fooXbar+baz", true),
        ("foo+bar", "https://example.com/foo+bar", true),
        ("path(test)", "https://example.com/path(test)", true),
        ("foo|bar", "https://example.com/foo", true),
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

        #expect(arrayPolicy.patterns == stringPolicy.patterns)
        #expect(arrayPolicy.matches(try #require(URL(string: "https://example.com"))))
        #expect(arrayPolicy.matches(try #require(URL(string: "https://other.test"))))
    }

    @Test func settingsStoreReadsLegacyArrayForTheEditor() async throws {
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
        #expect(defaults.object(forKey: key.userDefaultsKey) as? [String] == [" example.com ", "# ignored", "other.test"])

        defaults.set(["third.test"], forKey: key.userDefaultsKey)
        #expect(await store.value(for: key) == "third.test")
    }

    @Test func pathologicalRulesAreBoundedAndFailClosed() throws {
        let oversizedRegex = "re:" + String(repeating: "a", count: 4_097)
        let rules = (0..<300).map { "host\($0).example" } + [oversizedRegex]
        let policy = BrowserExternalURLPolicy(patterns: rules)
        let oversizedPolicy = BrowserExternalURLPolicy(patterns: [oversizedRegex])

        // The matcher retains a bounded snapshot, so a malformed or excessive
        // settings value cannot turn one navigation into unbounded work.
        #expect(policy.patterns.count == 256)
        #expect(!policy.matches(try #require(URL(string: "https://host299.example"))))
        #expect(!oversizedPolicy.matches(try #require(URL(string: "https://\(String(repeating: "a", count: 4_097))"))))
    }

    @Test func pathologicalRegexShapesAndLongTargetsFailClosed() {
        let policy = BrowserExternalURLPolicy(patterns: ["re:(a+)+$"])
        #expect(!policy.matches("https://\(String(repeating: "a", count: 8_192))b"))

        let adjacentQuantifiers = BrowserExternalURLPolicy(
            patterns: ["re:a*a*a*a*a*a*a*a*b"]
        )
        #expect(!adjacentQuantifiers.matches("https://\(String(repeating: "a", count: 8_192))"))

        let countedQuantifiers = BrowserExternalURLPolicy(
            patterns: ["re:^a{1,}a{1,}a{1,}a{1,}$"]
        )
        #expect(!countedQuantifiers.matches("https://\(String(repeating: "a", count: 8_192))"))

        let multiStarGlob = BrowserExternalURLPolicy(
            patterns: ["*a*a*a*a*a*a*b*a"]
        )
        #expect(!multiStarGlob.matches("https://\(String(repeating: "a", count: 8_192))c"))

        let ordinaryPolicy = BrowserExternalURLPolicy(patterns: ["example.com"])
        #expect(ordinaryPolicy.matches("https://example.com/\(String(repeating: "x", count: 16_384))"))
    }
}
