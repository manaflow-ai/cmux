import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Toggle Omnibar with `motion.renderServer` on lays out once and moves on the render server:
/// the page resizes once per toggle on both engines, the rows slide as additive
/// `position.y` springs over the page's own background and the row fades as an additive opacity; a
/// page in its own window lands with the views over it and only the rows move; with the overlays gate
/// off the change lands in one frame. With the switch off (the default) no render spring runs.
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

        init(_ page: any BrowserTab, renderServer: Bool = true) {
            self.page = page
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            window = NSWindow(contentRect: NSRect(x: screen.minX + 10, y: screen.minY + 10, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil,
                                       rendersMotionOnServer: { renderServer })
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

    /// A Chromium stand-in drawn in the chrome (host mode, `.inView`) or in its own window (`.childWindow`).
    static func mockPage(_ presentation: BrowserPresentation = .inView, background: CGColor? = nil) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
            .makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        tab.presentation = presentation
        tab.pageBackgroundColor = background
        return tab
    }

    static func engines() -> [any BrowserTab] {
        let mock = mockPage()
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

    @Test func theGapShowsThePagesBackground() throws {
        try with(animations: true) {
            let dark = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
            let host = Host(Self.mockPage(background: dark))
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
            host.toggle()
            host.toggle()
            // On show the page keeps its top edge and leaves a row-high gap under it while it slides.
            #expect(!host.chrome.pageGutter.isHidden, "no gutter under the sliding page")
            #expect(host.chrome.pageGutter.layer?.backgroundColor == dark, "the gap does not show the page's background")
            #expect(host.chrome.pageGutter.frame == host.chrome.contentContainer.frame)
            // The landing takes the gutter away.
            host.chrome.landToolbarToggle(host.chrome.toolbarToggles)
            #expect(host.chrome.pageGutter.isHidden)
        }
    }

    @Test func aSeeThroughPageGetsNoGutter() throws {
        try with(animations: true) {
            let host = Host(Self.mockPage(background: nil))
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
            host.toggle()
            #expect(host.chrome.pageGutter.isHidden, "a see-through page got a gutter that hides what is behind it")
        }
    }

    /// A Chromium page in its own window is placed from the page host's frame: the host and the bars
    /// over the page land with it, where their occlusion holes are, and only the rows move.
    @Test func aChildWindowPageLandsWithTheViewsOverIt() throws {
        try with(animations: true) {
            let host = Host(Self.mockPage(.childWindow, background: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
            defer { host.tearDown() }
            try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
            try #require(Motion.overlays.animatesMovement, "overlays movement is off in this host's settings")
            host.chrome.showFindBar()
            host.chrome.layoutSubtreeIfNeeded()
            for _ in 0..<2 {
                host.toggle()
                #expect(Self.springs(host.chrome.contentContainer.layer).isEmpty, "the child-window page host slid")
                #expect(!Self.springs(host.chrome.findBar.layer).contains("position.y"), "the find bar slid off its hole")
                #expect(Self.springs(host.chrome.promptBar.layer).isEmpty)
                #expect(Self.springs(host.chrome.toolbar.layer).contains("position.y"), "the row does not slide")
                #expect(host.chrome.pageGutter.isHidden, "a gutter under a page window nobody sees")
            }
            #expect(host.pageResizes == 2)
        }
    }

    /// `motion.renderServer` off (the default): the rows' frames animate on the main thread, as before
    /// this task; no render spring runs and the hidden row takes no height once it lands.
    @Test func offTheRenderServerNoRenderSpringRuns() throws {
        try with(animations: true) {
            for page in Self.engines() {
                let host = Host(page, renderServer: false)
                defer { host.tearDown() }
                try #require(Motion.canAnimate(in: host.chrome), "the test window has no screen: nothing animates")
                host.toggle()
                #expect(Self.springs(host.chrome.contentContainer.layer).isEmpty, "\(page.engineKind): a render spring ran with the switch off")
                #expect(Self.springs(host.chrome.toolbar.layer).isEmpty)
                #expect(host.chrome.pendingToolbarSlide == nil)
                #expect(host.chrome.toolbar.frame.height == 0, "the step path parked the row")
                #expect(host.chrome.contentContainer.frame.maxY == host.chrome.bounds.maxY)
                host.toggle()
                #expect(Self.springs(host.chrome.contentContainer.layer).isEmpty)
                #expect(host.chrome.toolbar.alphaValue == 1)
            }
        }
    }
}
