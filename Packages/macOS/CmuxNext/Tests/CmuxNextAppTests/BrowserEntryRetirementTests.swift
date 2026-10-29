import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import Testing

/// The entry owns the chrome. Its page must leave that hierarchy before AppKit destroys the
/// chrome: Chromium's hierarchy probe can otherwise register a weak reference to a dying view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct BrowserEntryRetirementTests {
    @Test func releasingAnEntryRetiresItsPageBeforeItsChrome() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        weak var released: BrowserEntry?
        autoreleasepool {
            var entry: BrowserEntry? = BrowserEntry(tab: page)
            released = entry
            entry?.chrome.isHidden = true
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

    @Test func releasingAnEntryOffMainRetiresItsPageOnMain() async {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let owner = EntryOwner(BrowserEntry(tab: page))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); page.close() }
        window.contentView = owner.entry.withLock { $0?.chrome }
        let probe = PageDetachmentProbe()
        page.contentView.addSubview(probe)
        #expect(probe.window === window)
        await withCheckedContinuation { done in
            probe.onLeaveWindow = { done.resume() }
            // task-owner: releases the last entry reference off main, then ends
            Task.detached {
                owner.entry.withLock {
                    #expect(!Thread.isMainThread)
                    $0 = nil
                }
            }
        }
        #expect(page.isClosed)
        #expect(page.contentView.superview == nil)
    }

    private nonisolated final class EntryOwner: Sendable {
        let entry: Mutex<BrowserEntry?>

        init(_ entry: BrowserEntry) {
            self.entry = Mutex(entry)
        }
    }

    private final class PageDetachmentProbe: NSView {
        var onLeaveWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil else { return }
            let callback = onLeaveWindow
            onLeaveWindow = nil
            callback?()
        }
    }
}
