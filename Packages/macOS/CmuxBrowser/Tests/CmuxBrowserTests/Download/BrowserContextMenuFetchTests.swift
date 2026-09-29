import Foundation
import Testing
@testable import CmuxBrowser

/// "Copy Image" and context-menu downloads fetch outside WebKit. A page can
/// point the image at any host, so the fetch must carry only the cookies that
/// host would receive from WebKit, including after a redirect.
@Suite("Browser context-menu fetch")
struct BrowserContextMenuFetchTests {
    private static func cookie(name: String, domain: String, path: String = "/") throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name,
            .value: "\(name)-value",
            .domain: domain,
            .path: path,
        ]))
    }

    private static func cookieNames(in request: URLRequest) -> Set<String> {
        guard let header = request.value(forHTTPHeaderField: "Cookie") else { return [] }
        return Set(header.split(separator: ";").compactMap { pair in
            pair.split(separator: "=", maxSplits: 1).first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
        })
    }

    private static func profileCookies() throws -> [HTTPCookie] {
        [
            try cookie(name: "bank-session", domain: ".bank.test"),
            try cookie(name: "mail-session", domain: "mail.test"),
            try cookie(name: "cdn-pref", domain: ".images.test"),
        ]
    }

    @Test("an image on another host receives none of the profile's other cookies")
    func imageHostReceivesOnlyItsOwnCookies() throws {
        let url = try #require(URL(string: "https://evil.test/pixel.png"))
        let request = BrowserContextMenuFetch.request(
            url: url,
            profileCookies: try Self.profileCookies(),
            referer: "https://bank.test/account",
            userAgent: "cmux-test"
        )

        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://bank.test/account")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "cmux-test")
    }

    @Test("an image on a cookie's own host still receives that cookie")
    func imageHostReceivesMatchingCookie() throws {
        let url = try #require(URL(string: "https://cdn.images.test/photo.png"))
        let request = BrowserContextMenuFetch.request(
            url: url,
            profileCookies: try Self.profileCookies(),
            referer: nil,
            userAgent: nil
        )

        #expect(Self.cookieNames(in: request) == ["cdn-pref"])
    }

    @Test("a redirect to another host drops the first host's cookies")
    func redirectRescopesCookies() throws {
        let cookies = try Self.profileCookies()
        let first = BrowserContextMenuFetch.request(
            url: try #require(URL(string: "https://bank.test/image.png")),
            profileCookies: cookies,
            referer: nil,
            userAgent: nil
        )
        #expect(Self.cookieNames(in: first) == ["bank-session"])

        // URLSession copies the original headers onto the redirect request.
        var redirect = first
        redirect.url = try #require(URL(string: "https://evil.test/collect.png"))
        let rescoped = BrowserContextMenuFetch.redirectedRequest(redirect, profileCookies: cookies)
        #expect(rescoped.value(forHTTPHeaderField: "Cookie") == nil)

        redirect.url = try #require(URL(string: "https://mail.test/avatar.png"))
        let toMail = BrowserContextMenuFetch.redirectedRequest(redirect, profileCookies: cookies)
        #expect(Self.cookieNames(in: toMail) == ["mail-session"])
    }
}
