import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser download URL normalizer")
struct BrowserDownloadURLNormalizerTests {
    private let normalizer = BrowserDownloadURLNormalizer()

    @Test
    func repeatedPageQueryItemsDoNotTrap() throws {
        let url = try #require(URL(
            string: "https://mail.google.com/mail/u/0/?permmsgid=msg-f:1&permmsgid=msg-f:2"
        ))

        #expect(normalizer.normalize(url) == url)
    }

    @Test
    func caseInsensitiveRedirectQueryCollisionsKeepFirstValue() throws {
        let url = try #require(URL(
            string: "https://www.google.com/url?Url=https://a.example/x&url=https://b.example/y"
        ))

        #expect(normalizer.normalize(url) == URL(string: "https://a.example/x"))
    }

    @Test(arguments: [
        "https://notgoogle.example/url?url=https://a.example/x",
        "https://google.example.com/url?url=https://b.example/y",
    ])
    func lookalikeGoogleHostsRemainUnchanged(_ string: String) throws {
        let url = try #require(URL(string: string))

        #expect(normalizer.normalize(url) == url)
    }

    @Test
    func escapedRedirectValuesAreNotDecodedTwice() throws {
        let url = try #require(URL(
            string: "https://www.google.com/url?url=https%3A%2F%2Fa.example%2Fdownload%2Fa%252Fb%3Fsig%3Dabc%25252Fdef"
        ))

        let expected = try #require(URL(
            string: "https://a.example/download/a%2Fb?sig=abc%252Fdef"
        ))
        #expect(normalizer.normalize(url) == expected)
    }
}
