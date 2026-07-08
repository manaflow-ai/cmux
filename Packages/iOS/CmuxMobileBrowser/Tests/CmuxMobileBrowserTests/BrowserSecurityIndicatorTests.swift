import Foundation
import Testing

@testable import CmuxMobileBrowser

/// Pure URL classification for the address-bar security indicator.
@Suite struct BrowserSecurityIndicatorTests {
    @Test func nilURLShowsNoIndicator() {
        #expect(BrowserSecurityIndicator.state(for: nil) == .none)
    }

    @Test func httpsURLIsSecure() {
        let url = URL(string: "https://example.com")!
        #expect(BrowserSecurityIndicator.state(for: url) == .secure)
    }

    @Test func publicHTTPURLIsInsecure() {
        let url = URL(string: "http://example.com")!
        #expect(BrowserSecurityIndicator.state(for: url) == .insecure)
    }

    @Test(arguments: [
        "http://localhost:3000",
        "http://127.0.0.1:8080",
        "http://[::1]:8080",
        "http://10.0.0.5",
        "http://172.16.0.1",
        "http://192.168.1.10",
    ])
    func localAndPrivateHTTPURLsShowNoIndicator(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(BrowserSecurityIndicator.state(for: url) == .none)
    }

    @Test(arguments: [
        "file:///tmp/index.html",
        "about:blank",
    ])
    func nonWebURLsShowNoIndicator(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(BrowserSecurityIndicator.state(for: url) == .none)
    }
}
