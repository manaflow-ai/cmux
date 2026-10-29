import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Testing

/// The entry owns the chrome. Its page must leave that hierarchy before AppKit destroys the
/// chrome: Chromium's hierarchy probe can otherwise register a weak reference to a dying view.
@MainActor @Suite(.serialized) struct BrowserEntryRetirementTests {
    @Test func releasingAnEntryRetiresItsPageBeforeItsChrome() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        weak var released: BrowserEntry?
        autoreleasepool {
            var entry: BrowserEntry? = BrowserEntry(tab: page)
            released = entry
            #expect(page.contentView.superview != nil)
            entry = nil
        }
        #expect(released == nil)
        #expect(page.isClosed, "releasing the owner must close even a page that was never presented")
        #expect(page.contentView.superview == nil, "the page must not outlive its chrome's hierarchy")
        page.close()
    }

    @Test func closingAnEntryDetachesItsContentWhileItsChromeIsStillAlive() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let entry = BrowserEntry(tab: page)
        entry.chrome.isHidden = true
        entry.close()
        #expect(page.isClosed)
        #expect(page.contentView.superview == nil)
        entry.close()
    }
}
