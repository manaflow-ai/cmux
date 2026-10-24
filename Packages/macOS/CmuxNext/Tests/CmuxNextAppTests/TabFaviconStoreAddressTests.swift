@testable import CmuxNextApp
import CmuxNextBrowser
import Testing

/// The favicon store keys icons by the address string (no `URL` parse or `URL.==` per lookup: a
/// strip and the sidebar look up every tab's icon on each pass). Only web addresses are fetched,
/// the scheme in any case, as `URL.scheme` compared lowercased before.
@MainActor
struct TabFaviconStoreAddressTests {
    @Test(arguments: [
        ("https://example.com/favicon.ico", true), ("http://example.com/a.png", true),
        ("HTTPS://Example.com/x.ico", true), ("Http://a.b/c", true),
        ("file:///tmp/a.png", false), ("data:image/png;base64,AAAA", false), ("cmux-page://x/y", false),
        ("https:/missing-slash", false), ("", false), ("ftp://a/b", false),
    ])
    func onlyWebAddressesAreFetched(address: String, web: Bool) {
        #expect(TabFaviconStore.isWebAddress(address) == web)
    }
}
