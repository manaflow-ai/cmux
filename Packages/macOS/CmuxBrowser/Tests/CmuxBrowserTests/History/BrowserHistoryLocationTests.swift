import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryLocationTests {
    @Test func foldsDebugAndStagingNamespaces() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app.debug.my-tag") == "com.cmuxterm.app.debug")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app.staging.rc") == "com.cmuxterm.app.staging")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app") == "com.cmuxterm.app")
    }

    @Test func historyFileURLNestsUnderNamespace() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let location = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app.debug.tag")
        #expect(location.namespace == "com.cmuxterm.app.debug")
        #expect(location.historyFileURL.path == "/tmp/appsupport/com.cmuxterm.app.debug/browser_history.json")
    }

    @Test func legacyURLPresentOnlyWhenNamespaceDiffers() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let tagged = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app.debug.tag")
        #expect(tagged.legacyTaggedHistoryFileURL?.path == "/tmp/appsupport/com.cmuxterm.app.debug.tag/browser_history.json")

        let prod = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app")
        #expect(prod.legacyTaggedHistoryFileURL == nil)
    }
}
