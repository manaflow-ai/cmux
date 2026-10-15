import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium cookie write SameSite and path")
struct BrowserChromiumCookieWriteSameSiteTests {
    @Test func secureCookieWithoutPolicyIsSameSiteNoneAndInsecureStaysUnspecified() throws {
        let secure = try #require(HTTPCookie(properties: [.name: "a", .value: "1", .domain: ".a.example", .path: "/", .secure: "TRUE"]))
        let plain = try #require(HTTPCookie(properties: [.name: "a", .value: "1", .domain: ".a.example", .path: "/"]))
        #expect(BrowserChromiumCookieWrite(cookie: secure)?.sameSite == .noRestriction)
        #expect(BrowserChromiumCookieWrite(cookie: plain)?.sameSite == .unspecified)
    }

    @Test func relativePathBecomesRoot() throws {
        let cookie = try #require(HTTPCookie(properties: [.name: "a", .value: "1", .domain: ".a.example", .path: "foo"]))
        let write = try #require(BrowserChromiumCookieWrite(cookie: cookie))
        #expect(write.path == "/")
        #expect(write.url.path == "/")
    }
}
