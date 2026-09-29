import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromeExtensionNavigationPolicyTests {
    private let id = "bcjindcccaagfpapjjmafapmmgkkhgoa"

    @Test(arguments: [
        "https://example.com/",
        "http://localhost:3000/x",
        "about:blank",
        "chrome-extension://bcjindcccaagfpapjjmafapmmgkkhgoa/options.html",
    ])
    func allowsWebAndOwnPages(_ raw: String) throws {
        #expect(ChromeExtensionNavigationPolicy.allows(try #require(URL(string: raw)), fromExtensionID: id))
    }

    @Test(arguments: [
        "javascript:alert(document.cookie)",
        "file:///etc/passwd",
        "data:text/html,<script>1</script>",
        "blob:https://example.com/uuid",
        "cmux://extensions",
        "cmux-diff-viewer://x",
        "about:srcdoc",
        "chrome-extension://nngceckbapebfimnlniiiahkandclblb/popup.html",
        "ftp://example.com/",
    ])
    func refusesPrivilegedAndForeignURLs(_ raw: String) throws {
        #expect(!ChromeExtensionNavigationPolicy.allows(try #require(URL(string: raw)), fromExtensionID: id))
    }
}
