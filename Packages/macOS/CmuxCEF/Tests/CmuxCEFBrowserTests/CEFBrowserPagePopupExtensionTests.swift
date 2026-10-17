import CmuxBrowser
import CmuxCEF
import CmuxCEFExtensions
import Foundation
import Testing
@testable import CmuxCEFBrowser

@MainActor
private final class NoExtensionCalls: CEFExtensionCalls {
    var forkAPIVersion: Int32 { 13 }
    func list(browser: Int32) -> String? { "[]" }
    func commands(browser: Int32) -> String? { "[]" }
    func actions(browser: Int32, iconPixels: Int32) -> String? { "[]" }
    func setEnabled(browser: Int32, id: String, enabled: Bool) -> Bool { false }
    func uninstall(browser: Int32, id: String) -> Bool { false }
    func reload(browser: Int32, id: String) -> Bool { false }
    func movePinned(browser: Int32, id: String, index: Int) -> Bool { false }
    func setPinned(browser: Int32, id: String, pinned: Bool) -> Bool { false }
    func openOptions(browser: Int32, id: String) -> Bool { false }
    func loadUnpacked(browser: Int32, path: String) -> Bool { false }
    func runCommand(browser: Int32, id: String, command: String) -> Bool { false }
    func runAction(browser: Int32, id: String, x: Int32, width: Int32) -> Bool { false }
    func hidePopup(browser: Int32, id: String) {}
    func showActionMenu(browser: Int32, id: String, x: Int32, y: Int32) {}
    func replyToPrompt(_ promptID: Int32, answer: Int32) -> Bool { false }
    func windowID(browser: Int32) -> Int32 { 0 }
}

/// A tab Chromium opens for a page (`window.open`, an extension's
/// `chrome.tabs.create`) is a cmux tab of the same profile, so it hosts the
/// same extensions: toolbar actions, popups and `cmux browser extension`.
@MainActor
@Suite
struct CEFBrowserPagePopupExtensionTests {
    private let layoutStore = BrowserDevToolsLayoutStore(
        defaults: UserDefaults(suiteName: "CEFBrowserPagePopupExtensionTests.\(UUID().uuidString)")!
    )

    @Test func aPopupPageHostsTheOpenersExtensions() {
        let profile = UUID()
        let stores = CEFExtensionStores(calls: NoExtensionCalls())
        let opener = CEFBrowserPage(
            browser: CEFBrowser(configuration: CEFBrowserConfiguration(profile: profile)),
            shim: { nil }, devToolsLayoutStore: layoutStore, extensions: stores
        )
        defer { opener.close() }
        let popup = opener.makePopupPage(for: CEFBrowser(configuration: CEFBrowserConfiguration(profile: profile)))
        defer { popup.close() }
        #expect(popup.extensionSupport != nil)
        #expect(popup.extensionSupport?.profileID == profile)
        #expect(popup.extensionHost?.extensionStore === opener.extensionHost?.extensionStore)
    }

    @Test func aPopupOfAPageWithoutExtensionsHasNone() {
        let opener = CEFBrowserPage(
            browser: CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID())),
            shim: { nil }, devToolsLayoutStore: layoutStore
        )
        defer { opener.close() }
        let popup = opener.makePopupPage(for: CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID())))
        defer { popup.close() }
        #expect(popup.extensionSupport == nil)
    }
}
