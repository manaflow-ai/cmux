import Testing

@testable import CmuxBrowser

@Suite("Browser REPL public suffix list")
struct BrowserReplPublicSuffixListTests {
    @Test(arguments: [
        ("www.example.com", "example.com"),
        ("a.b.example.co.uk", "example.co.uk"),
        ("x.co.at", "x.co.at"),
        ("a.x.co.at", "x.co.at"),
        ("co.at", "co.at"),
        ("ada.github.io", "ada.github.io"),
        ("a.b.ck", "a.b.ck"),
        ("www.ck", "www.ck"),
        ("foo.bar.unlisted", "foo.bar.unlisted"),
        ("localhost", "localhost"),
        ("127.0.0.1", "127.0.0.1"),
        ("[::1]", "[::1]"),
        (".docs.google.com", "google.com"),
        ("WWW.Example.COM.", "example.com"),
        ("www.食狮.公司.cn", "xn--85x722f.xn--55qx5d.cn"),
    ])
    func sitesOfTheSystemList(host: String, site: String) {
        #expect(BrowserReplPublicSuffixList.system.site(of: host) == site)
    }

    @Test func withoutTheSystemListEveryHostIsItsOwnSite() {
        let list = BrowserReplPublicSuffixList(isPublicSuffix: { _ in false })
        #expect(list.site(of: "a.b.example.com") == "a.b.example.com")
        #expect(list.site(of: "localhost") == "localhost")
    }

    @Test func theSessionAnswersSitesFromTheList() throws {
        let boundary = BrowserReplBoundary(publicSuffixes: BrowserReplPublicSuffixList(isPublicSuffix: { ["at", "co.at"].contains($0) }))
        let (result, updated) = boundary.policyOperation("site", ["host": "shop.x.co.at"])
        #expect(try result.get() as? String == "x.co.at")
        #expect(updated == nil)
    }
}
