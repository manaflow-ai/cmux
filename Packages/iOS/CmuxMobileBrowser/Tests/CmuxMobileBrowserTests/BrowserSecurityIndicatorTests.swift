import Foundation
import Testing

@testable import CmuxMobileBrowser

/// Pure URL classification for the address-bar security indicator.
@Suite struct BrowserSecurityIndicatorTests {
    @Test func nilURLShowsNoIndicator() {
        #expect(BrowserSecurityIndicator(url: nil) == .none)
    }

    @Test func httpsURLIsSecure() {
        let url = URL(string: "https://example.com")!
        #expect(BrowserSecurityIndicator(url: url) == .secure)
    }

    @Test(arguments: [
        "http://example.com",
        // DNS names that merely start with IPv6 private-prefix text are public.
        "http://fda.gov",
        "http://fe80.example.com",
        // Outside the CGNAT 100.64.0.0/10 range.
        "http://100.128.0.1",
    ])
    func publicHTTPURLIsInsecure(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(BrowserSecurityIndicator(url: url) == .insecure)
    }

    @Test(arguments: [
        "http://localhost:3000",
        "http://127.0.0.1:8080",
        "http://[::1]:8080",
        "http://10.0.0.5",
        "http://172.16.0.1",
        "http://192.168.1.10",
        "http://169.254.169.254",
        "http://100.100.1.50",
        "http://[fd00::1]",
        "http://[fe80::1]",
        "http://[::ffff:127.0.0.1]",
    ])
    func localAndPrivateHTTPURLsShowNoIndicator(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(BrowserSecurityIndicator(url: url) == .none)
    }

    @Test(arguments: [
        "file:///tmp/index.html",
        "about:blank",
    ])
    func nonWebURLsShowNoIndicator(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(BrowserSecurityIndicator(url: url) == .none)
    }
}
