import Foundation
import Testing
@testable import CmuxCEF

@Suite
struct CEFBrowserCreationTests {
    /// A page created with its URL starts the first navigation before its
    /// owner registers document-start scripts, so the first document ran
    /// without console capture or init scripts. The URL loads from
    /// `windowCreated()` instead, after `onWindowCreated`.
    @Test func aPageIsCreatedWithoutNavigating() throws {
        let url = try #require(URL(string: "https://example.com/"))
        #expect(CEFBrowser.creationURL(pendingURL: url, isPlaceholder: false) == "")
        #expect(CEFBrowser.creationURL(pendingURL: nil, isPlaceholder: false) == "")
    }

    @Test func aPopupPlaceholderLoadsItsBlankPageAtCreation() throws {
        let blank = try #require(URL(string: "about:blank"))
        #expect(CEFBrowser.creationURL(pendingURL: blank, isPlaceholder: true) == "about:blank")
    }
}
