import CmuxSettings
import Foundation
import Testing

@Suite struct BrowserURLAllowlistFileURLTests {
    @Test func localFileURLsRemainAvailableForUserAllowlist() throws {
        let policy = BrowserURLAllowlistPolicy(
            managedPatterns: nil,
            userPatterns: ["reports.example.com"]
        )
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))

        #expect(policy.source == .user)
        #expect(policy.isActive)
        // Local documents never leave the Mac: both the page/delegate path and
        // the app-owned trusted seam keep them open unless a profile forces
        // `BrowserAllowLocalFiles` off.
        #expect(policy.allows(fileURL))
        #expect(policy.allowsTrustedInternalURL(fileURL))
    }

    @Test func forcingLocalFilesOffDeniesBothPathsForAUserAllowlist() throws {
        let policy = BrowserURLAllowlistPolicy(
            managedPatterns: nil,
            userPatterns: ["reports.example.com"],
            allowsLocalFiles: false
        )
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))

        #expect(!policy.allows(fileURL))
        #expect(!policy.allowsTrustedInternalURL(fileURL))
        #expect(policy.allows(try #require(URL(string: "https://reports.example.com"))))
    }

    @Test func localFileURLsRemainAvailableForManagedAllowlist() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: ["reports.example.com"])
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))

        #expect(policy.isManaged)
        #expect(policy.isActive)
        #expect(policy.allows(fileURL))
        #expect(policy.allowsTrustedInternalURL(fileURL))
        #expect(!policy.allows(try #require(URL(string: "https://outside.example"))))
    }

    @Test func emptyManagedAllowlistAllowsLocalDocumentsThroughTrustedPath() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: [])
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))
        let remoteURL = try #require(URL(string: "https://outside.example"))

        #expect(policy.isManaged)
        #expect(policy.isActive)
        #expect(policy.allows(fileURL))
        #expect(policy.allowsTrustedInternalURL(fileURL))
        #expect(!policy.allows(remoteURL))
    }

    @Test func onlyLocalFileURLsUseTheTrustedExemption() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: ["reports.example.com"])
        let localhostFileURL = try #require(URL(string: "file://localhost/tmp/cmux-report.html"))
        let networkFileURL = try #require(URL(string: "file://build-host/tmp/cmux-report.html"))
        let relativeFileURL = try #require(URL(string: "file:relative-report.html"))
        let credentialedFileURL = try #require(URL(string: "file://user:password@localhost/tmp/cmux-report.html"))

        #expect(policy.allows(localhostFileURL))
        #expect(policy.allowsTrustedInternalURL(localhostFileURL))
        // Only well-formed local file URLs qualify, on either path.
        for url in [networkFileURL, relativeFileURL, credentialedFileURL] {
            #expect(!policy.allows(url))
            #expect(!policy.allowsTrustedInternalURL(url))
        }
    }

    @Test(arguments: ["file://", "file://*", "file:///*", "file:*", "*"])
    func malformedFileAndWildcardEntriesRemainNonRules(_ entry: String) {
        #expect(BrowserURLAllowlistPattern(entry) == nil)
    }

    @Test func bareFileEntryRemainsAnHTTPHostRuleOnly() throws {
        let pattern = try #require(BrowserURLAllowlistPattern("file"))
        let httpURL = try #require(URL(string: "https://file/status"))
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))

        #expect(pattern.matches(httpURL))
        #expect(!pattern.matches(fileURL))
    }

    @Test func wildcardDoesNotAllowRemoteOrigins() throws {
        let policy = BrowserURLAllowlistPolicy(managedPatterns: ["*"])
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))
        let remoteURL = try #require(URL(string: "https://outside.example"))

        #expect(policy.isActive)
        #expect(policy.patterns.isEmpty)
        #expect(policy.allows(fileURL))
        #expect(policy.allowsTrustedInternalURL(fileURL))
        #expect(!policy.allows(remoteURL))
    }
}
