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
    ]

    private func cleared(_ params: [String: Any], persistent: Bool = true) throws -> [String] {
        let scope = try BrowserReplCookieClearScope(params: params, storeIsPersistent: persistent)
        return Self.jar
            .filter { scope.includes(name: $0.name, domain: $0.domain, path: $0.path) }
            .map { "\($0.domain) \($0.name)" }
    }

    @Test func refusesAnUnscopedClearOfAPersistentProfile() {
        #expect(throws: BrowserReplCookieClearScope.Refusal.self) {
            try cleared([:])
        }
        #expect(throws: BrowserReplCookieClearScope.Refusal.self) {
            try cleared(["name": "sid", "site": ""])
        }
    }

    @Test func aSiteSelectsItsDomainAndSubdomainsOnly() throws {
        #expect(try cleared(["site": "example.com"]) == [".example.com sid", "www.example.com pref", "api.example.com sid"])
        #expect(try cleared(["site": "EXAMPLE.com"]).count == 3)
    }

    @Test func filtersMatchExactlyInsideTheSite() throws {
        #expect(try cleared(["site": "example.com", "name": "sid"]) == [".example.com sid", "api.example.com sid"])
        #expect(try cleared(["site": "example.com", "domain": "api.example.com"]) == ["api.example.com sid"])
        #expect(try cleared(["site": "example.com", "path": "/v1"]) == ["api.example.com sid"])
        #expect(try cleared(["site": "example.com", "domain": "other.org"]).isEmpty)
    }

    @Test func allSelectsEverySiteAndOverridesSite() throws {
        #expect(try cleared(["all": true]).count == Self.jar.count)
        #expect(try cleared(["all": true, "site": "example.com", "name": "sid"]).count == 4)
    }

    @Test func aStoreThatIsNotPersistentMayBeClearedWhole() throws {
        #expect(try cleared([:], persistent: false).count == Self.jar.count)
        #expect(try cleared(["name": "pref"], persistent: false) == ["www.example.com pref"])
    }
}
