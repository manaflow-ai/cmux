import Foundation
import Testing

@testable import CEFKit

@Suite("CEFProfile cache directory mapping")
struct CEFProfileDirectoryTests {
    @Test func supportedNamesMapDirectly() {
        #expect(CEFProfile.cacheDirectoryName(for: "Default") == "Profile-Default")
        #expect(CEFProfile.cacheDirectoryName(for: "work_2-a") == "Profile-work_2-a")
    }

    /// Regression: character replacement alone is not injective; "Work?" and
    /// "Work!" both sanitize to "Work-". Distinct profile names must never
    /// share a cache directory (cookies/storage would silently merge).
    @Test func sanitizedNamesStayDistinct() {
        let a = CEFProfile.cacheDirectoryName(for: "Work?")
        let b = CEFProfile.cacheDirectoryName(for: "Work!")
        #expect(a != b)
        #expect(!a.contains("?"))
        #expect(!b.contains("!"))
    }

    /// The appended hash must be stable across process launches (djb2 of the
    /// original name), or every launch would abandon the previous profile
    /// directory. Pinned against independently computed values.
    @Test func sanitizedNamesAreStableAcrossLaunches() {
        #expect(CEFProfile.cacheDirectoryName(for: "Work?") == "Profile-Work--310e642507")
        #expect(CEFProfile.cacheDirectoryName(for: "Work!") == "Profile-Work--310e6424e9")
    }

    @Test func directoryNamesHaveNoPathSeparators() {
        // Chrome-bootstrap CEF requires profile directories to be direct
        // children of the root cache path; a separator would nest them.
        let name = CEFProfile.cacheDirectoryName(for: "../escape/attempt")
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
    }
}
