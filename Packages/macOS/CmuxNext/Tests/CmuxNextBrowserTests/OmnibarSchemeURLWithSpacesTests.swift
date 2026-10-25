@testable import CmuxNextBrowser
import Foundation
import Testing

/// An address with an explicit http, https or file scheme and a space after
/// its host loads, with the space percent-encoded, as in Chrome: a pasted
/// search URL or a file with a space in its name. Text without a scheme,
/// and a space inside the host, still search.
struct OmnibarSchemeURLWithSpacesTests {
    @Test(arguments: [
        ("https://www.google.com/search?q=hello world", "https://www.google.com/search?q=hello%20world"),
        ("http://localhost:3000/a b/c", "http://localhost:3000/a%20b/c"),
        ("file:///Users/me/My Notes.html", "file:///Users/me/My%20Notes.html"),
        ("https://example.com/docs#a section", "https://example.com/docs#a%20section"),
    ])
    func aSchemeURLWithASpaceAfterItsHostLoads(_ input: String, _ expected: String) throws {
        let url = try #require(BrowserURLResolver().url(for: input), "\(input) was searched")
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: ["https://exa mple.com/", "http://foo bar", "https: is a protocol", "swift testing", "example.com/a b"])
    func otherTextWithSpacesStillSearches(_ input: String) {
        #expect(BrowserURLResolver().url(for: input) == nil)
    }
}
