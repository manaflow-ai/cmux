import CmuxNextBrowser
import CmuxNextBrowserImport
@testable import CmuxNextApp
import Foundation
import Testing

@Suite struct BrowserCookieImportSecurityTests {
    @Test func importPreservesHostOnlyAndDomainCookieScope() throws {
        let hostOnly = ImportedCookie(
            name: "session", value: "test-value", domain: "accounts.example.com",
            secure: true, httpOnly: true
        )
        let hostOnlyWrite = try #require(AppCookieDestination.write(for: hostOnly))
        #expect(hostOnlyWrite.url.host == "accounts.example.com")
        #expect(hostOnlyWrite.domain.isEmpty)

        let domain = ImportedCookie(
            name: "preference", value: "test-value", domain: ".example.com",
            secure: true
        )
        let domainWrite = try #require(AppCookieDestination.write(for: domain))
        #expect(domainWrite.url.host == "example.com")
        #expect(domainWrite.domain == ".example.com")
    }
}
