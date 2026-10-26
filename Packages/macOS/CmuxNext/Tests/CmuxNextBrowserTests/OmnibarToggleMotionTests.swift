import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Toggle Omnibar commits once and moves on the render server (p03-rendering-102): the page
/// resizes once per toggle on both engines, the rows slide as additive `position.y` springs, the
/// row fades as an additive opacity, and with the overlays gate off the change lands in one frame.
@MainActor @Suite(.serialized) struct OmnibarToggleMotionTests {
    @MainActor final class Host {
        let window: NSWindow
        let chrome: BrowserChromeView
        let page: any BrowserTab
        private(set) var pageResizes = 0
        private var pageSize = NSSize.zero
        private var observer: NSObjectProtocol?

        init(_ page: any BrowserTab) {
            self.page = page
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            chrome = BrowserChromeView(tab: page)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
            let content = page.contentView
            content.postsFrameChangedNotifications = true
            pageSize = content.frame.size
            // Posted synchronously on the thread that set the frame: the main thread.
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageFrameChanged() }
            }
        }

        private func pageFrameChanged() {
            let size = page.contentView.frame.size
            guard size != pageSize else { return }
            pageSize = size
            pageResizes += 1
        }

        func tearDown() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    static func engines() -> [any BrowserTab] {
        let mock = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
            .makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let webKit = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        return [mock, webKit]
    }

    /// Runs `body` with the overlays gate moving (`enabled`) or still, then puts the switches back.
    func with(animations enabled: Bool, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (oldEnabled, oldSpeed) = (design.animationsEnabled, design.animationSpeed)
        Motion.reduceMotionOverride = false
        design.animationSpeed = .fast
        design.animationsEnabled = enabled
        defer {
            design.animationsEnabled = oldEnabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    static func toggleKeys(_ layer: CALayer?) -> [String] {
        (layer?.animationKeys() ?? []).filter { $0.hasPrefix("omnibarToggle.") }
    }

    @Test func eachToggleResizesThePageOnceOnBothEngines() throws {
        try with(animations: true) {
            for page in Self.engines() {
                let host = Host(page)
                defer { host.tearDown() }
                try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen")
                let rowHeight = host.chrome.toolbar.frame.height

                host.chrome.toggleOmnibar()
                #expect(host.pageResizes == 1, "\(page.engineKind): the page resized \(host.pageResizes) times on hide")
                #expect(host.chrome.toolbar.frame.height == rowHeight, "the row resized instead of moving")
                #expect(!Self.toggleKeys(host.chrome.contentContainer.layer).isEmpty, "the page host does not slide")
                #expect(Self.toggleKeys(host.chrome.toolbar.layer).contains { $0.hasSuffix(".opacity") }, "the row does not fade")
                #expect(!host.chrome.toolbar.isHidden, "the row hid before its slide landed")

                host.chrome.toggleOmnibar()
                #expect(host.pageResizes == 2, "\(page.engineKind): the page resized \(host.pageResizes) times on show")
                // The slide adds no layout of its own: a later pass finds the page at rest already.
                host.chrome.layoutSubtreeIfNeeded()
                #expect(host.pageResizes == 2)
            }
        }
    }

    @Test func aResizedPageKeepsItsTopEdgeOnScreen() {
        let old = NSRect(x: 0, y: 0, width: 900, height: 560)
        let new = NSRect(x: 0, y: 0, width: 900, height: 600)
        // Not flipped (y up): the top is maxY; the page is shown 40 pt lower, where its top was.
        #expect(BrowserChromeView.rowShift(from: old, to: new, flipped: false) == -40)
        // A row that kept its height moves whole.
        let row = NSRect(x: 0, y: 560, width: 900, height: 40)
        #expect(BrowserChromeView.rowShift(from: row, to: row.offsetBy(dx: 0, dy: 40), flipped: false) == -40)
    }

    @Test func theGateOffLandsInOneFrameAndHidesTheRowOnce() {
        with(animations: false) {
            let host = Host(Self.engines()[0])
            defer { host.tearDown() }
            host.chrome.toggleOmnibar()
            #expect(host.chrome.toolbar.isHidden, "the landing did not run with the gate off")
            #expect(host.chrome.separator.isHidden)
            #expect(Self.toggleKeys(host.chrome.contentContainer.layer).isEmpty)
            #expect(Self.toggleKeys(host.chrome.toolbar.layer).isEmpty)
            host.chrome.layoutSubtreeIfNeeded()
            #expect(host.pageResizes == 1)
            #expect(host.chrome.contentContainer.frame.maxY == host.chrome.bounds.maxY)

            host.chrome.toggleOmnibar()
            #expect(!host.chrome.toolbar.isHidden)
            host.chrome.layoutSubtreeIfNeeded()
            #expect(host.pageResizes == 2)
        }
    }

    @Test func aStaleLandingDoesNotHideAShownRow() throws {
        try with(animations: true) {
            let host = Host(Self.engines()[0])
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen")
            host.chrome.toggleOmnibar()
            let hide = host.chrome.toolbarToggles
            host.chrome.toggleOmnibar()
            // The hide's transaction lands after the show started: its completion must not hide the row.
            host.chrome.finishToolbarToggle(hide)
            #expect(!host.chrome.toolbar.isHidden, "the hide's landing hid the row the show brought back")
            #expect(host.chrome.toolbar.alphaValue == 1)
            host.chrome.toggleOmnibar()
            host.chrome.finishToolbarToggle(host.chrome.toolbarToggles)
            #expect(host.chrome.toolbar.isHidden, "the latest hide's landing did not hide the row")
        }
    }
}
