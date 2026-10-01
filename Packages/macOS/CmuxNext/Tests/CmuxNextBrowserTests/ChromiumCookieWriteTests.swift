import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct ChromiumCookieWriteTests {
    let cookie = ChromiumCookieWrite(
        url: URL(string: "https://github.com/")!, name: "user_session", value: "SECRET", domain: "github.com", path: "/",
        secure: true, httpOnly: true, sameSite: .lax, expires: Date(timeIntervalSince1970: 1_900_000_000),
        created: Date(timeIntervalSince1970: 0), lastAccess: nil
    )

    @Test func shimJSONCarriesEveryField() throws {
        let json = try ChromiumCookieWrite.shimJSON([cookie])
        let list = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let entry = try #require(list.first)
        #expect(entry["url"] as? String == "https://github.com/")
        #expect(entry["domain"] as? String == "github.com")
        #expect(entry["secure"] as? Bool == true && entry["httponly"] as? Bool == true)
        // cef_cookie_same_site_t: LAX_MODE = 2.
        #expect(entry["same_site"] as? Int == 2)
        #expect(entry["has_expires"] as? Bool == true)
        // cef_basetime_t: microseconds since 1601, exact as a string.
        #expect(entry["expires"] as? String == "13544473600000000")
        #expect(entry["creation"] as? String == "11644473600000000")
        #expect(entry["last_access"] as? String == "0")
    }

    @Test func sessionCookieHasNoExpiry() throws {
        var session = cookie
        session.expires = nil
        let json = try ChromiumCookieWrite.shimJSON([session])
        #expect(json.contains("\"has_expires\":false"))
    }

    @Test func descriptionHidesTheValue() {
        #expect(!"\(cookie)".contains("SECRET"))
    }

    @Test func parsesTheShimReply() {
        #expect(ChromiumCookieWriteResult.parse(#"{"written":3,"rejected":1}"#) == ChromiumCookieWriteResult(written: 3, rejected: 1))
        #expect(ChromiumCookieWriteResult.parse("[]") == nil)
    }
}
