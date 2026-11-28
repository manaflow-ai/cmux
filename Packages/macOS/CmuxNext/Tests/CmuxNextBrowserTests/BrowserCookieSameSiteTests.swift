import CmuxNextBrowser
import Foundation
import Testing

struct BrowserCookieSameSiteTests {
    @Test(arguments: ["lax", "strict", "none"])
    func sameSiteSurvivesFoundationConversion(_ sameSite: String) throws {
        for httpOnly in [false, true] {
            let value = BrowserCookie(name: "session", value: "private", domain: ".example.com", path: "/",
                expires: nil, secure: true, httpOnly: httpOnly, sameSite: sameSite.capitalized)
            let cookie = try #require(value.httpCookie)
            #expect(cookie.sameSitePolicy?.rawValue.lowercased() == sameSite)
            #expect(cookie.isHTTPOnly == httpOnly)
        }
    }

    @Test func sameSiteCannotInjectAnotherCookieAttribute() {
        let cookie = BrowserCookie(name: "session", value: "private", domain: "example.com", path: "/",
            expires: nil, secure: true, httpOnly: true, sameSite: "Strict; Domain=other.test")
        #expect(cookie.httpCookie == nil)
    }
}
