import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL cookies.clear scope")
struct BrowserReplCookieClearScopeTests {
    private struct Cookie: Sendable {
        let name: String
        let domain: String
        let path: String
    }

    private static let jar: [Cookie] = [
        Cookie(name: "sid", domain: ".example.com", path: "/"),
        Cookie(name: "pref", domain: "www.example.com", path: "/"),
        Cookie(name: "sid", domain: "api.example.com", path: "/v1"),
        Cookie(name: "sid", domain: ".notexample.com", path: "/"),
        Cookie(name: "sid", domain: "other.org", path: "/"),
        Cookie(name: "sid", domain: "x.co.at", path: "/"),
        Cookie(name: "sid", domain: ".y.co.at", path: "/"),
    ]

    private static let suffixes = BrowserReplPublicSuffixList(isPublicSuffix: { ["com", "org", "at", "co.at"].contains($0) })

    private func cleared(_ params: [String: Any], tab: String?, persistent: Bool = true) throws -> [String] {
        let scope = try BrowserReplCookieClearScope(
            params: params,
            tabURL: tab.flatMap(URL.init(string:)),
            storeIsPersistent: persistent,
            publicSuffixes: Self.suffixes
        )
        return Self.jar
            .filter { scope.includes(name: $0.name, domain: $0.domain, path: $0.path) }
            .map { "\($0.domain) \($0.name)" }
    }

    @Test func theTabsSiteIsClearedWhateverSiteTheCallerNames() throws {
        #expect(try cleared([:], tab: "https://www.example.com/a") == [".example.com sid", "www.example.com pref", "api.example.com sid"])
        #expect(try cleared(["site": "other.org"], tab: "https://WWW.Example.com/") == [".example.com sid", "www.example.com pref", "api.example.com sid"])
    }

    @Test func aSiteUnderAMultiLabelPublicSuffixStaysOnItsOwnDomain() throws {
        #expect(try cleared([:], tab: "https://a.x.co.at/") == ["x.co.at sid"])
    }

    @Test func aTabWithNoSiteIsRefusedOnTheProfile() {
        #expect(throws: BrowserReplCookieClearScope.Refusal.self) { try cleared([:], tab: "about:blank") }
        #expect(throws: BrowserReplCookieClearScope.Refusal.self) { try cleared(["site": "example.com"], tab: nil) }
    }

    @Test func allIsRefusedOnTheProfile() {
        #expect(throws: BrowserReplCookieClearScope.Refusal.self) { try cleared(["all": true], tab: "https://example.com/") }
    }

    @Test func filtersMatchExactlyInsideTheSite() throws {
        #expect(try cleared(["name": "sid"], tab: "https://example.com/") == [".example.com sid", "api.example.com sid"])
        #expect(try cleared(["domain": "api.example.com"], tab: "https://example.com/") == ["api.example.com sid"])
        #expect(try cleared(["path": "/v1"], tab: "https://example.com/") == ["api.example.com sid"])
        #expect(try cleared(["domain": "other.org"], tab: "https://example.com/").isEmpty)
    }

    @Test func aStoreThatIsNotPersistentMayBeClearedWhole() throws {
        #expect(try cleared(["all": true], tab: "https://example.com/", persistent: false).count == Self.jar.count)
        #expect(try cleared([:], tab: "about:blank", persistent: false).count == Self.jar.count)
        #expect(try cleared(["name": "pref"], tab: nil, persistent: false) == ["www.example.com pref"])
        #expect(try cleared([:], tab: "https://example.com/", persistent: false).count == 3)
    }
}
