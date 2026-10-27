import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Toggle Omnibar lays out once and moves on the render server (p03-rendering-102): the page
/// resizes once per toggle on both engines, the rows slide as additive `position.y` springs and the
/// row fades as an additive opacity, and with the overlays gate off the change lands in one frame.
///
/// The spring checks read the layers' animations, so the window is real and ordered in; a host where
/// nothing animates (no screen, a sleeping display) fails them (`#require`), it does not skip them.
@MainActor @Suite(.serialized) struct OmnibarToggleMotionTests {
    @MainActor final class Host {
        let window: NSWindow
        let chrome: BrowserChromeView
        let page: any BrowserTab
        private(set) var pageResizes = 0
        private var pageSize = CGSize.zero
        private var observer: (any NSObjectProtocol)?

        init(_ page: any BrowserTab) {
            self.page = page
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            window = NSWindow(contentRect: NSRect(x: screen.minX + 10, y: screen.minY + 10, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
            let content = page.contentView
            content.postsFrameChangedNotifications = true
            pageSize = content.frame.size
            // Posted synchronously on the thread that set the frame: the main thread.
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageFrameChanged() }
            }
        }

        private func pageFrameChanged() {
            let size = page.contentView.frame.size
            guard size != pageSize else { return }
            pageSize = size
            pageResizes += 1
        }

        /// Toggles and runs the one layout the change asked for, as the next display cycle does.
        func toggle() {
            chrome.toggleOmnibar()
            chrome.layoutSubtreeIfNeeded()
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

    /// The key paths of `layer`'s `RenderSpring` springs (`cmux.renderSpring.<serial>.<keyPath>`).
    static func springs(_ layer: CALayer?) -> [String] {
        let prefix = "cmux.renderSpring."
        return (layer?.animationKeys() ?? []).filter { $0.hasPrefix(prefix) }.compactMap { key in
            key.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).last.map(String.init)
        }
    }

    @Test func eachToggleResizesThePageOnceOnBothEngines() throws {
        try with(animations: true) {
            for page in Self.engines() {
                let host = Host(page)
                defer { host.tearDown() }
                try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
                try #require(Motion.overlays.animatesMovement, "overlays movement is off in this host's settings")
                let rowHeight = host.chrome.toolbar.frame.height

                host.toggle()
                #expect(host.pageResizes == 1, "\(page.engineKind): the page resized \(host.pageResizes) times on hide")
                #expect(host.chrome.toolbar.frame.height == rowHeight, "the row resized instead of moving")
                #expect(Self.springs(host.chrome.contentContainer.layer).contains("position.y"), "the page host does not slide")
                #expect(Self.springs(host.chrome.toolbar.layer).contains("position.y"), "the row does not slide")
                #expect(Self.springs(host.chrome.toolbar.layer).contains("opacity"), "the row does not fade")
                #expect(!host.chrome.toolbar.isHidden, "the row hid before its slide landed")

                host.toggle()
                #expect(host.pageResizes == 2, "\(page.engineKind): the page resized \(host.pageResizes) times on show")
                // The slide adds no layout of its own: a later pass finds the page at rest already.
                host.chrome.needsLayout = true
                host.chrome.layoutSubtreeIfNeeded()
                #expect(host.pageResizes == 2)
            }
        }
    }

    @Test func aResizedPageKeepsItsTopEdgeWhereItShowed() {
        let old = CGRect(x: 0, y: 0, width: 900, height: 560)
        let new = CGRect(x: 0, y: 0, width: 900, height: 600)
        // Not flipped (y up): the top is maxY; the page shows 40 pt lower, where its top was.
        #expect(BrowserChromeView.rowShift(from: old, to: new, flipped: false) == -40)
        // Flipped (y down): the top is minY.
        #expect(BrowserChromeView.rowShift(from: old.offsetBy(dx: 0, dy: 40), to: new, flipped: true) == 40)
        // A row that kept its height moves whole.
        let row = CGRect(x: 0, y: 560, width: 900, height: 40)
        #expect(BrowserChromeView.rowShift(from: row, to: row.offsetBy(dx: 0, dy: 40), flipped: false) == -40)
    }

    @Test func theGateOffLandsInOneFrameAndHidesTheRow() {
        with(animations: false) {
            let host = Host(Self.engines()[0])
            defer { host.tearDown() }
            host.toggle()
            #expect(host.chrome.toolbar.isHidden, "the landing did not run with the gate off")
            #expect(host.chrome.separator.isHidden)
            #expect(Self.springs(host.chrome.contentContainer.layer).isEmpty)
            #expect(Self.springs(host.chrome.toolbar.layer).isEmpty)
            #expect(host.pageResizes == 1)
            #expect(host.chrome.contentContainer.frame.maxY == host.chrome.bounds.maxY)

            host.toggle()
            #expect(!host.chrome.toolbar.isHidden)
            #expect(host.chrome.toolbar.alphaValue == 1)
            #expect(host.pageResizes == 2)
        }
    }

    @Test func aStaleLandingDoesNotHideAShownRow() throws {
        try with(animations: true) {
            let host = Host(Self.engines()[0])
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
            host.toggle()
            let hide = host.chrome.toolbarToggles
            host.toggle()
            // The hide's springs land after the show started: its landing must not hide the row.
            host.chrome.landToolbarToggle(hide)
            #expect(!host.chrome.toolbar.isHidden, "the hide's landing hid the row the show brought back")
            #expect(host.chrome.toolbar.alphaValue == 1)
            host.toggle()
            host.chrome.landToolbarToggle(host.chrome.toolbarToggles)
            #expect(host.chrome.toolbar.isHidden, "the latest hide's landing did not hide the row")
        }
    }

    @Test func twoTogglesBeforeOneLayoutMoveNothing() throws {
        try with(animations: true) {
            let host = Host(Self.engines()[0])
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
            host.chrome.toggleOmnibar()
            host.chrome.toggleOmnibar()
            host.chrome.layoutSubtreeIfNeeded()
            #expect(host.pageResizes == 0)
            #expect(Self.springs(host.chrome.contentContainer.layer).isEmpty, "a hide and a show in one turn slid the page")
            #expect(!host.chrome.toolbar.isHidden)
        }
    }
}
