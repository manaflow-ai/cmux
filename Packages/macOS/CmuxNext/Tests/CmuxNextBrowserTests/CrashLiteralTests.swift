import Foundation
import Testing
@testable import CmuxNextBrowser

/// Crash program: literal URLs and the default profile id are built without a force
/// unwrap; these pin that every literal parses (the /dev/null stand-in never runs).
@MainActor @Suite struct BrowserCrashLiteralTests {
    @Test func literalsParse() {
        #expect(URL.browserExtensionWebStore.absoluteString == "https://chromewebstore.google.com/category/extensions")
        #expect(URL.browserExtensionManagement.absoluteString == "chrome://extensions")
        #expect(BrowserProfileID.default.rawValue.uuidString == "8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11")
    }
}
