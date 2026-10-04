import Foundation
import Testing
@testable import CmuxNextBrowser

/// Agent-driven tabs never load, show or script Chromium's own pages
/// (plans/cmux-next/passwords.md, section 2): `chrome://password-manager`
/// can hand a saved password or a CSV export to its script after the user
/// answers a device-auth prompt the agent caused.
@Suite struct AgentURLPolicyTests {
    @Test(arguments: [
        "chrome://password-manager/passwords",
        "chrome://settings/passwords",
        "chrome://extensions",
        "CHROME://password-manager",
        "chrome:password-manager",
        "  chrome://settings",
        "chr\tome://settings",
        "chrome\n://settings",
        "chrome-extension://nngceckbapebfimnlniiiahkandclblb/popup/index.html",
        "chrome-untrusted://print/",
        "devtools://devtools/bundled/inspector.html",
        "chrome-devtools://devtools/bundled/inspector.html",
        "chrome-search://local-ntp/",
        "view-source:https://example.com/",
        "view-source:chrome://settings",
        "about:settings",
        "about:password-manager",
        "ABOUT:Extensions",
        "blob:chrome://settings/0b4f",
        "filesystem:chrome-extension://abc/temporary/x",
    ])
    func refused(_ text: String) {
        #expect(AgentURLPolicy.refuses(text), "\(text.debugDescription)")
    }

    @Test(arguments: [
        "https://example.com/",
        "http://localhost:3000/login",
        "about:blank",
        "about:blank#top",
        "about:srcdoc",
        "file:///tmp/page.html",
        "data:text/html,hi",
        "blob:https://example.com/0b4f",
        "chromium.org",
        "",
    ])
    func allowed(_ text: String) {
        #expect(!AgentURLPolicy.refuses(text), "\(text.debugDescription)")
    }

    @Test func urlOverloadAgrees() throws {
        #expect(AgentURLPolicy.refuses(try #require(URL(string: "chrome://password-manager/passwords"))))
        #expect(!AgentURLPolicy.refuses(try #require(URL(string: "https://accounts.example.com/"))))
    }
}
