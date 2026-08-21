import CmuxSettings
import Foundation
import Testing

struct BrowserURLAllowlistPolicyTests {
    @Test(arguments: [
        ("example.com", "https://example.com/path", true),
        ("example.com", "https://www.example.com/path", false),
        ("*.example.com", "https://www.example.com/path", true),
        ("*.example.com", "https://example.com/path", false),
        ("https://git.example.com", "http://git.example.com", false),
        ("https://git.example.com", "https://git.example.com", true),
        ("http://localhost:3000", "http://localhost:3000/app", true),
        ("http://localhost:3000", "http://localhost:4000/app", false),
        ("localhost", "http://localhost:3000/app", true),
        ("localhost", "https://localhost:9443/app", true),
        ("127.0.0.1", "http://127.0.0.1:5173", true),
        ("::1", "http://[::1]:8080", true),
        ("*.localhost", "http://dev.localhost:3000", true),
        ("*.localhost", "http://localhost:3000", false),
        ("localhost", "http://cmux-loopback.localtest.me:3000", true),
    ])
    func patternMatchesExpected(rule: String, urlString: String, expected: Bool) throws {
        let pattern = try #require(BrowserURLAllowlistPattern(rule))
        let url = try #require(URL(string: urlString))
        #expect(pattern.matches(url) == expected)
    }

    @Test func malformedRulesAreRejected() {
        #expect(BrowserURLAllowlistPattern("") == nil)
        #expect(BrowserURLAllowlistPattern("ftp://example.com") == nil)
        #expect(BrowserURLAllowlistPattern("https://example.com/path") == nil)
        #expect(BrowserURLAllowlistPattern("example.com:99999") == nil)
        #expect(BrowserURLAllowlistPattern("example.com:not-a-port") == nil)
        #expect(BrowserURLAllowlistPattern("*example.com") == nil)
    }

    @Test func internalCmuxDocumentsRemainAvailableWhenManaged() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: ["internal.example.com"])
        #expect(policy.isManaged)
        #expect(policy.isActive)
        #expect(policy.allows(try #require(URL(string: "about:blank"))))
        #expect(policy.allows(try #require(URL(string: "cmux-diff-viewer://session/1"))))
        #expect(!policy.allows(try #require(URL(string: "https://outside.example"))))
    }

    @Test func anEmptyManagedArrayFailsClosed() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: [])
        #expect(policy.isManaged)
        #expect(!policy.allows(try #require(URL(string: "https://example.com"))))
        #expect(policy.allows(try #require(URL(string: "file:///tmp/index.html"))))
    }

    @Test func userRulesAreOptionalAndEmptyMeansAllowAll() throws {
        let unrestricted = BrowserURLAllowlistPolicy(managedPatterns: nil)
        #expect(!unrestricted.isActive)
        #expect(unrestricted.allows(try #require(URL(string: "https://example.com"))))

        let restricted = BrowserURLAllowlistPolicy(
            managedPatterns: nil,
            userPatterns: ["dev.example.com"]
        )
        #expect(restricted.source == .user)
        #expect(restricted.allows(try #require(URL(string: "https://dev.example.com"))))
        #expect(!restricted.allows(try #require(URL(string: "https://example.com"))))
    }

    @Test func forcedValueWinsOverUserValueAndReleaseFallback() throws {
        let appSuiteName = "BrowserURLAllowlistPolicyTests.app.\(UUID().uuidString)"
        let releaseSuiteName = "BrowserURLAllowlistPolicyTests.release.\(UUID().uuidString)"
        let appDefaults = try #require(UserDefaults(suiteName: appSuiteName))
        let releaseDefaults = try #require(UserDefaults(suiteName: releaseSuiteName))
        defer {
            appDefaults.removePersistentDomain(forName: appSuiteName)
            releaseDefaults.removePersistentDomain(forName: releaseSuiteName)
        }

        appDefaults.set(["user.example"], forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        releaseDefaults.set(["managed.example"], forKey: "forced.\(BrowserURLAllowlistPolicy.managedDefaultsKey)")
        let probe: ManagedDevicePolicy.ForcedObjectProbe = { defaults, key in
            defaults.object(forKey: "forced.\(key)")
        }
        let managedResolver = ManagedDevicePolicy(
            defaults: appDefaults,
            releaseDomainDefaults: releaseDefaults,
            forcedObject: probe
        )
        let policy = BrowserURLAllowlistPolicy(
            defaults: appDefaults,
            managedDevicePolicy: managedResolver
        )

        #expect(policy.source == .managed)
        #expect(policy.allows(try #require(URL(string: "https://managed.example"))))
        #expect(!policy.allows(try #require(URL(string: "https://user.example"))))
    }
}
