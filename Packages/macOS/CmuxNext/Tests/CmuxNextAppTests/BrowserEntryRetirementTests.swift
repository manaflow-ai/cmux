import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTestSupport
import Testing

/// The entry owns the chrome. Its page must leave that hierarchy before AppKit destroys the
/// chrome: Chromium's hierarchy probe can otherwise register a weak reference to a dying view.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct BrowserEntryRetirementTests {
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
        // The chrome is read here, on main: returning it out of the Mutex's nonisolated closure is a
        // main-actor value sent out of its isolation, which strict concurrency refuses. The scope ends
        // the local `entry`, so the owner holds the only reference the detached task releases.
        let chrome: NSView
        let owner: EntryOwner
        do {
            let entry = BrowserEntry(tab: page)
            chrome = entry.chrome
            owner = EntryOwner(entry)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); page.close() }
        window.contentView = chrome
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
