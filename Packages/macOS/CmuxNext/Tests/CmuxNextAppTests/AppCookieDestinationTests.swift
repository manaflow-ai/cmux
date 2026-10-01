import CmuxNextBrowser
import CmuxNextBrowserImport
@testable import CmuxNextApp
import Foundation
import Synchronization
import Testing

/// The App side of the cookie import, with a fake Chromium writer.
@Suite struct AppCookieDestinationTests {
    @Test func mapsFieldsAndProfile() async throws {
        let seen = Mutex<[(ChromiumCookieWrite, BrowserProfileID)]>([])
        let destination = AppCookieDestination { writes, profile in
            seen.withLock { $0 += writes.map { ($0, profile) } }
            return ChromiumCookieWriteResult(written: writes.count, rejected: 0)
        }
        let profile = UUID()
        let cookies = [
            ImportedCookie(name: "sid", value: "v", domain: ".example.com", path: "/app", secure: true, httpOnly: true, sameSite: .none,
                           expires: Date(timeIntervalSince1970: 2_000_000_000)),
            ImportedCookie(name: "broken", value: "v", domain: ""),
        ]
        let result = try await destination.setCookies(cookies, profileID: profile.uuidString.lowercased())
        #expect(result == CookieWriteResult(written: 1, rejected: 1))
        let (write, target) = try #require(seen.withLock { $0.first })
        #expect(target == BrowserProfileID(rawValue: profile))
        #expect(write.url.absoluteString == "https://example.com/app")
        #expect(write.domain == ".example.com" && write.sameSite == .noRestriction && write.secure && write.httpOnly)
        #expect(write.expires == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func unknownTargetGoesToDefaultProfile() async throws {
        let seen = Mutex<BrowserProfileID?>(nil)
        let destination = AppCookieDestination { writes, profile in
            seen.withLock { $0 = profile }
            return ChromiumCookieWriteResult(written: writes.count, rejected: 0)
        }
        _ = try await destination.setCookies([ImportedCookie(name: "a", value: "b", domain: "a.example")], profileID: "default")
        #expect(seen.withLock { $0 } == .default)
    }
}
