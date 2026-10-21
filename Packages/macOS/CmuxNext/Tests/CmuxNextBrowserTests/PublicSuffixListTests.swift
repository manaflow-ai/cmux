@testable import CmuxNextBrowser
import Testing

/// The Public Suffix List decides which page may see an email's code
/// (plans/cmux-next/email-verification-autofill/DESIGN.md, rule 4): a wrong
/// registrable domain would let one site read another site's code.
@Suite struct PublicSuffixListTests {
    let list = PublicSuffixList.bundled()

    @Test func theBundledListLoads() throws {
        #expect(try #require(list).ruleCount > 9000)
    }

    @Test(arguments: [
        ("github.com", "github.com"),
        ("accounts.github.com", "github.com"),
        ("Mail.GitHub.COM.", "github.com"),
        ("www.bbc.co.uk", "bbc.co.uk"),
        ("someone.github.io", "someone.github.io"),
        ("deep.someone.github.io", "someone.github.io"),
        ("github.com.evil.io", "evil.io"),
        ("a.b.example.nom.br", "b.example.nom.br"),
        ("www.ck", "www.ck"),
        ("shop.example.ck", "shop.example.ck"),
    ])
    func registrableDomains(host: String, expected: String) throws {
        #expect(try #require(list).registrableDomain(of: host) == expected)
    }

    /// A public suffix, an IP, a bare label, or a malformed host has no site,
    /// so nothing can match it.
    @Test(arguments: ["co.uk", "github.io", "com", "localhost", "192.168.1.10", "[::1]", "", ".", "a..b.com", "bücher.de"])
    func hostsWithoutASite(host: String) throws {
        #expect(try #require(list).registrableDomain(of: host) == nil)
    }

    @Test func aSmallListFollowsTheAlgorithm() {
        let small = PublicSuffixList(listText: "// comment\ncom\n*.ck\n!www.ck\nco.uk\nuk\n")
        #expect(small.registrableDomain(of: "a.b.com") == "b.com")
        #expect(small.registrableDomain(of: "x.y.ck") == "x.y.ck")
        #expect(small.registrableDomain(of: "www.ck") == "www.ck")
        #expect(small.registrableDomain(of: "a.bbc.co.uk") == "bbc.co.uk")
        // The default rule "*": an unknown top-level label is a suffix.
        #expect(small.registrableDomain(of: "a.b.zz") == "b.zz")
    }
}

extension PublicSuffixListTests {
    /// A missing list must fail closed: with only the default rule, "co.uk" would be a site.
    @Test func anEmptyListDecidesNothing() {
        #expect(PublicSuffixList(listText: "").registrableDomain(of: "www.bbc.co.uk") == nil)
    }
}
