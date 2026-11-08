import Foundation
import Testing

@testable import CmuxBrowser

/// Turning decoded Safari records into the cookies an import writes.
@Suite struct SafariCookieImportPreparationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        domain: String = ".example.com",
        name: String = "session",
        path: String = "/",
        value: String = "abc",
        expiresDate: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) -> SafariBinaryCookie {
        SafariBinaryCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expiresDate: expiresDate,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly
        )
    }

    @Test func convertsEveryAttributeOfALiveCookie() throws {
        let expiry = now.addingTimeInterval(3_600)
        let preparation = SafariCookieImportPreparation(domainFilters: [], date: now)

        let prepared = preparation.prepare([
            record(path: "/account", expiresDate: expiry, isSecure: true, isHTTPOnly: true),
        ])

        let cookie = try #require(prepared.cookies.first)
        #expect(prepared.cookies.count == 1)
        #expect(prepared.expiredCount == 0)
        #expect(cookie.domain == ".example.com")
        #expect(cookie.name == "session")
        #expect(cookie.path == "/account")
        #expect(cookie.value == "abc")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.expiresDate == expiry)
    }

    @Test func keepsSecureAndHTTPOnlyOffWhenSafariDidNotSetThem() throws {
        let preparation = SafariCookieImportPreparation(domainFilters: [], date: now)

        let cookie = try #require(preparation.prepare([record()]).cookies.first)

        #expect(!cookie.isSecure)
        #expect(!cookie.isHTTPOnly)
        #expect(cookie.isSessionOnly)
    }

    @Test func givesAnEmptyPathTheRootPath() throws {
        let preparation = SafariCookieImportPreparation(domainFilters: [], date: now)

        let cookie = try #require(preparation.prepare([record(path: "")]).cookies.first)

        #expect(cookie.path == "/")
    }

    @Test func countsExpiredCookiesAndLeavesThemOut() {
        let preparation = SafariCookieImportPreparation(domainFilters: [], date: now)

        let prepared = preparation.prepare([
            record(name: "old", expiresDate: now.addingTimeInterval(-1)),
            record(name: "edge", expiresDate: now),
            record(name: "live", expiresDate: now.addingTimeInterval(1)),
        ])

        #expect(prepared.cookies.map(\.name) == ["live"])
        #expect(prepared.expiredCount == 2)
    }

    @Test func skipsCookiesOutsideTheDomainFiltersWithoutCountingThem() {
        let preparation = SafariCookieImportPreparation(domainFilters: ["example.com"], date: now)

        let prepared = preparation.prepare([
            record(domain: ".login.example.com", name: "kept"),
            record(domain: ".other.net", name: "filtered"),
            record(domain: ".other.net", name: "filteredExpired", expiresDate: now.addingTimeInterval(-1)),
        ])

        #expect(prepared.cookies.map(\.name) == ["kept"])
        #expect(prepared.expiredCount == 0)
    }

    @Test func skipsCookiesWithoutAName() {
        let preparation = SafariCookieImportPreparation(domainFilters: [], date: now)

        let prepared = preparation.prepare([record(name: "")])

        #expect(prepared.cookies.isEmpty)
        #expect(prepared.expiredCount == 0)
    }
}
