import Foundation
import AppKit
import Testing
@testable import CmuxBrowser

@Suite("BrowserInsecureHTTPRepository")
struct BrowserInsecureHTTPRepositoryTests {
    @Test("default allowlist patterns are present")
    func defaultAllowlistPatternsArePresent() {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        #expect(
            repository.normalizedAllowlistPatterns(rawValue: nil)
                == ["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]
        )
    }

    @Test("wildcard and exact host matching")
    func wildcardAndExactHostMatching() {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        #expect(repository.isHostAllowed("localhost", rawAllowlist: nil))
        #expect(repository.isHostAllowed("a.localhost", rawAllowlist: nil))
        #expect(repository.isHostAllowed("deep.a.localhost", rawAllowlist: nil))
        #expect(repository.isHostAllowed("127.0.0.1", rawAllowlist: nil))
        #expect(!repository.isHostAllowed("a.127.0.0.1", rawAllowlist: nil))
        #expect(repository.isHostAllowed("::1", rawAllowlist: nil))
        #expect(repository.isHostAllowed("0.0.0.0", rawAllowlist: nil))
        #expect(repository.isHostAllowed("api.localtest.me", rawAllowlist: nil))
        #expect(!repository.isHostAllowed("neverssl.com", rawAllowlist: nil))
    }

    @Test("custom allowlist normalizes and deduplicates entries")
    func customAllowlistNormalizesAndDeduplicatesEntries() {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        let raw = """
        localhost
        *.example.com
        127.0.0.1
        https://dev.internal:8080/path
        *.example.com
        """

        #expect(
            repository.normalizedAllowlistPatterns(rawValue: raw)
                == ["localhost", "*.example.com", "127.0.0.1", "dev.internal"]
        )
        #expect(repository.isHostAllowed("foo.example.com", rawAllowlist: raw))
        #expect(repository.isHostAllowed("dev.internal", rawAllowlist: raw))
        #expect(!repository.isHostAllowed("example.net", rawAllowlist: raw))
    }

    @Test("block decision uses allowlist and scheme rules")
    func blockDecisionUsesAllowlistAndSchemeRules() throws {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        let localURL = try #require(URL(string: "http://foo.localtest.me:3000"))
        #expect(!repository.shouldBlock(localURL, rawAllowlist: nil))

        let localhostSubdomainURL = try #require(URL(string: "http://a.localhost:3000"))
        #expect(!repository.shouldBlock(localhostSubdomainURL, rawAllowlist: nil))

        let insecureURL = try #require(URL(string: "http://neverssl.com"))
        #expect(repository.shouldBlock(insecureURL, rawAllowlist: nil))

        let httpsURL = try #require(URL(string: "https://neverssl.com"))
        #expect(!repository.shouldBlock(httpsURL, rawAllowlist: nil))
    }

    @Test("one-time bypass is consumed after first navigation")
    func oneTimeBypassIsConsumedAfterFirstNavigation() throws {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        let insecureURL = try #require(URL(string: "http://neverssl.com"))
        var bypassHostOnce: String? = "neverssl.com"

        #expect(repository.consumeOneTimeBypass(insecureURL, bypassHostOnce: &bypassHostOnce))
        #expect(bypassHostOnce == nil)

        // Subsequent visits should prompt again unless host was saved.
        #expect(!repository.consumeOneTimeBypass(insecureURL, bypassHostOnce: &bypassHostOnce))
        #expect(repository.shouldBlock(insecureURL, rawAllowlist: nil))
    }

    @Test("addAllowedHost persists to defaults and unblocks HTTP")
    func addAllowedHostPersistsToDefaultsAndUnblocksHTTP() throws {
        let suiteName = "BrowserInsecureHTTPRepositoryTests.Persist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let repository = BrowserInsecureHTTPRepository(defaults: defaults)
        let url = try #require(URL(string: "http://persist-me.test"))
        #expect(repository.shouldBlock(url))

        repository.addAllowedHost("persist-me.test")
        let persisted = defaults.string(forKey: BrowserInsecureHTTPRepository.allowlistKey)
        #expect(persisted != nil)
        #expect(repository.isHostAllowed("persist-me.test"))
        #expect(!repository.shouldBlock(url))
    }

    @Test("allowlist selection persists for proceed and open-external")
    func allowlistSelectionPersistsForProceedAndOpenExternal() {
        let repository = BrowserInsecureHTTPRepository(defaults: .standard)
        #expect(repository.shouldPersistAllowlistSelection(
            response: .alertFirstButtonReturn,
            suppressionEnabled: true
        ))
        #expect(repository.shouldPersistAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: true
        ))
        #expect(!repository.shouldPersistAllowlistSelection(
            response: .alertThirdButtonReturn,
            suppressionEnabled: true
        ))
        #expect(!repository.shouldPersistAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: false
        ))
    }
}
