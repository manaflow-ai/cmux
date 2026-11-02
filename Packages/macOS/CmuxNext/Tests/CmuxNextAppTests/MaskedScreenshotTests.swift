import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextHome
import CmuxNextPages
import CmuxNextScreenshots
import CmuxNextTabs
import CmuxNextTestSupport
import Testing
import WebKit

/// Agents and scripts screenshot windows, panes and tabs (Leo 2026-10-21: before/after
/// captures of the real app), but a browser page's pixels reach automation only through the
/// browser host's guarded capture, which hides secrets. Their capture
/// (`AppWindowImage.maskedCapture`, `ScreenshotMask`) masks every browser page area and chat.
/// The window here shows a green native view beside a browser pane whose page area is red (a
/// stand-in for the page's pixels): the person's raw capture shows the red, the agent's shows
/// the mask over the whole page area, no red pixel anywhere, and the green untouched.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct MaskedScreenshotTests {
    static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
    static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor

    struct Fixture {
        let window: NSWindow
        let plain: NSView
        let chrome: BrowserChromeView
        let page: WebKitTab

        /// The page area in window coordinates.
        var pageRect: NSRect { chrome.pageArea.convert(chrome.pageArea.bounds, to: nil) }
        /// The whole browser pane in window coordinates: what a capture masks.
        var chromeRect: NSRect { chrome.convert(chrome.bounds, to: nil) }

        func close() {
            chrome.closePopupPanels()
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    /// Whether AppKit can put a window on screen here (a fleet worker at the login window cannot).
    static func hostShowsWindows() -> Bool {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { return false }
        let probe = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.close() }
        probe.orderFrontRegardless()
        return probe.isVisible && probe.windowNumber > 0
    }

    func fixture(onScreen: Bool = true) -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        content.wantsLayer = true
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        plain.wantsLayer = true
        plain.layer?.backgroundColor = Self.green
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let chrome = BrowserChromeView(tab: page)
        chrome.frame = NSRect(x: 240, y: 0, width: 240, height: 240)
        content.addSubview(plain)
        content.addSubview(chrome)
        window.contentView = content
        if onScreen { window.orderFrontRegardless() }
        content.layoutSubtreeIfNeeded()
        // The page's own pixels: red over the whole page area.
        let pixels = NSView(frame: chrome.pageArea.bounds)
        pixels.autoresizingMask = [.width, .height]
        pixels.wantsLayer = true
        pixels.layer?.backgroundColor = Self.red
        chrome.pageArea.addSubview(pixels)
        content.displayIfNeeded()
        CATransaction.flush()
        return Fixture(window: window, plain: plain, chrome: chrome, page: page)
    }

    /// An image's pixels as sRGB RGBA bytes.
    struct Pixels {
        typealias RGBA = (red: Int, green: Int, blue: Int, alpha: Int)
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) {
            let wide = image.width, high = image.height
            var pixels = [UInt8](repeating: 0, count: wide * high * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
            }
            width = wide
            height = high
            bytes = pixels
        }

        /// The pixel at column `x` and row `y` counted from the bottom.
        func at(x: Int, y: Int) -> RGBA {
            let index = ((height - 1 - y) * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
        }

        /// The pixel at `point` (bottom-left origin, points) of an image of an area `size` points large.
        func at(_ point: CGPoint, size: CGSize) -> RGBA {
            let scale = CGFloat(width) / size.width
            return at(x: min(width - 1, Int(point.x * scale)), y: min(height - 1, Int(point.y * scale)))
        }

        /// Every pixel inside `rect` (window points) of an image of a window `size` points large.
        func all(in rect: NSRect, size: CGSize) -> [RGBA] {
            let scale = CGFloat(width) / size.width
            let xs = Int((rect.minX * scale).rounded(.up))..<min(width, Int((rect.maxX * scale).rounded(.down)))
            let ys = Int((rect.minY * scale).rounded(.up))..<min(height, Int((rect.maxY * scale).rounded(.down)))
            return xs.flatMap { x in ys.map { y in at(x: x, y: y) } }
        }

        var everyPixel: [RGBA] { (0..<width).flatMap { x in (0..<height).map { y in at(x: x, y: y) } } }
    }

    static func isRed(_ pixel: Pixels.RGBA) -> Bool { pixel.red > 180 && pixel.green < 90 && pixel.blue < 90 && pixel.alpha > 200 }
    static func isGreen(_ pixel: Pixels.RGBA) -> Bool { pixel.green > 180 && pixel.red < 90 && pixel.blue < 90 && pixel.alpha > 200 }
    /// `WindowImageLayer.maskColor`: opaque sRGB mid gray.
    static func isMask(_ pixel: Pixels.RGBA) -> Bool {
        [pixel.red, pixel.green, pixel.blue].allSatisfy { (125...130).contains($0) } && pixel.alpha == 255
    }

    /// The person's raw capture of the window once the window server shows the page's red.
    private func rawCapture(_ fixture: Fixture) async throws -> CGImage {
        let center = CGPoint(x: fixture.pageRect.midX, y: fixture.pageRect.midY)
        return try await Self.settledCapture(fixture.window) { Self.isRed(Pixels($0).at(center, size: fixture.window.frame.size)) }
    }

    /// `window`'s raw capture once `shows` holds for it, bounded. Until the window server composites a new window
    /// the capture can be all transparent, which `screenshotImage` throws as `.blank`: in a test process with no
    /// window before this one (#26809's heavy step on a CI mini) every test here threw it 0.2-0.6 s in. The last
    /// capture runs outside the loop, so a window that never shows still fails with that capture's own error or
    /// in the caller's checks.
    static func settledCapture(_ window: NSWindow, until shows: (CGImage) -> Bool) async throws -> CGImage {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if let image = try? await window.screenshotImage(includeChild: { _ in false }), shows(image) { return image }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return try await window.screenshotImage(includeChild: { _ in false })
    }

    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func anAgentsCaptureRunsAndMasksThePageAreaWhole() async throws {
        let fixture = fixture()
        defer { fixture.close() }
        let size = fixture.window.frame.size
        let page = fixture.pageRect
        let raw = Pixels(try await rawCapture(fixture))
        #expect(Self.isRed(raw.at(CGPoint(x: page.midX, y: page.midY), size: size)), "the raw capture shows the page: there is something to mask")

        let (image, masked) = try await AppWindowImage.maskedCapture(fixture.window)
        let shot = Pixels(image)
        #expect(masked >= 1)
        #expect(shot.width == raw.width && shot.height == raw.height)
        let inPage = shot.all(in: page, size: size)
        #expect(!inPage.isEmpty)
        #expect(inPage.allSatisfy(Self.isMask), "every pixel of the page area is masked")
        #expect(!shot.everyPixel.contains(where: Self.isRed), "no pixel of the page survives anywhere")
        let native = shot.all(in: fixture.plain.frame.insetBy(dx: 2, dy: 2), size: size)
        #expect(!native.isEmpty)
        #expect(native.allSatisfy(Self.isGreen), "pixels outside browser pages are left as they are")
    }

    /// The handler's choice: a socket run, even one claiming `user`, gets the masked image and
    /// `masked`; only a person's own run in the app gets the raw one. The pane crop is masked too.
    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func theHandlerMasksEverySocketRunAndOnlyThePersonsIsRaw() async throws {
        let fixture = fixture()
        defer { fixture.close() }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = fixture.pageRect
        _ = try await rawCapture(fixture)
        var claimed = ActionInvocation(origin: .user)
        claimed.viaControlSocket = true
        for invocation in [claimed, ActionInvocation(origin: .mcp), ActionInvocation(origin: .cli)] {
            let shot = try await ScreenshotHandlers.shown(fixture.window, crop: nil, for: invocation, services: services)
            #expect(shot.masked ?? 0 >= 1, "\(invocation.origin) is masked")
            #expect(!Pixels(shot.image).everyPixel.contains(where: Self.isRed))
            let crop = try await ScreenshotHandlers.shown(fixture.window, crop: fixture.chrome.pageArea, for: invocation, services: services)
            #expect(crop.masked != nil)
            #expect(Pixels(crop.image).everyPixel.allSatisfy(Self.isMask), "the page area crop is all mask")
        }
        let person = try await ScreenshotHandlers.shown(fixture.window, crop: nil, for: ActionInvocation(), services: services)
        #expect(person.masked == nil)
        #expect(Self.isRed(Pixels(person.image).at(CGPoint(x: page.midX, y: page.midY), size: fixture.window.frame.size)))
    }

    /// A pane's tab strip is a sibling of BrowserChromeView, so masking only the chrome leaves
    /// page-derived tab titles and badges visible. Both the full window and the pane crop must
    /// cover that strip for socket captures.
    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func aBrowserTabStripIsMaskedInWindowAndPaneCaptures() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 520, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "secret-title")]),
                                   reveal: reveal)
        let root = NSView(frame: window.contentLayoutRect)
        pane.frame = root.bounds.insetBy(dx: 20, dy: 20)
        root.addSubview(pane)
        window.contentView = root
        window.orderFrontRegardless()
        pane.layoutSubtreeIfNeeded()
        let titlePixels = NSView(frame: pane.stripView.bounds.insetBy(dx: 8, dy: 4))
        titlePixels.wantsLayer = true
        titlePixels.layer?.backgroundColor = Self.red
        pane.stripView.addSubview(titlePixels)
        let launch = NSView(frame: pane.contentHost.bounds)
        launch.wantsLayer = true
        launch.layer?.backgroundColor = Self.red
        pane.contentHost.addSubview(launch)
        pane.launchImageView = launch
        pane.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let stripRect = pane.stripView.convert(pane.stripView.bounds, to: nil)
        let launchRect = launch.convert(launch.bounds, to: nil)
        #expect(stripRect.width > 0 && stripRect.height > 0)
        #expect(launchRect.width > 0 && launchRect.height > 0)
        await ScreenshotMask.waitToSettle()
        let raw = try await Self.settledCapture(window) {
            Self.isRed(Pixels($0).at(CGPoint(x: stripRect.midX, y: stripRect.midY), size: window.frame.size))
                && Self.isRed(Pixels($0).at(CGPoint(x: launchRect.midX, y: launchRect.midY), size: window.frame.size))
        }
        #expect(Self.isRed(Pixels(raw).at(CGPoint(x: stripRect.midX, y: stripRect.midY), size: window.frame.size)),
                "the unmasked strip actually renders the sentinel over its secret title")
        #expect(Self.isRed(Pixels(raw).at(CGPoint(x: launchRect.midX, y: launchRect.midY), size: window.frame.size)),
                "the saved launch frame actually renders sensitive pixels")
        let services = AppServices(environment: AppEnvironment.current([:]))
        var invocation = ActionInvocation(origin: .user)
        invocation.viaControlSocket = true
        let full = try await ScreenshotHandlers.shown(window, crop: nil, for: invocation, services: services)
        let fullPixels = Pixels(full.image)
        #expect(full.masked ?? 0 >= 1)
        #expect(fullPixels.all(in: stripRect, size: window.frame.size).allSatisfy(Self.isMask),
                "tab titles and badges in the window strip are masked")
        #expect(fullPixels.all(in: launchRect, size: window.frame.size).allSatisfy(Self.isMask),
                "the saved launch frame stays masked alongside the strip")

        let crop = try await ScreenshotHandlers.shown(window, crop: pane, for: invocation, services: services)
        #expect(crop.masked ?? 0 >= 1)
        // Pixel helpers use a bottom-left origin, while PaneContentView is flipped.
        let paneRect = pane.convert(pane.bounds, to: nil)
        let croppedStrip = stripRect.offsetBy(dx: -paneRect.minX, dy: -paneRect.minY)
        let stripPixels = Pixels(crop.image).all(in: croppedStrip, size: pane.bounds.size)
        #expect(!stripPixels.isEmpty)
        #expect(stripPixels.allSatisfy(Self.isMask), "tab titles and badges in the pane crop are masked")
        let croppedLaunch = launchRect.offsetBy(dx: -paneRect.minX, dy: -paneRect.minY)
        let launchPixels = Pixels(crop.image).all(in: croppedLaunch, size: pane.bounds.size)
        #expect(!launchPixels.isEmpty)
        #expect(launchPixels.allSatisfy(Self.isMask), "the saved launch frame stays masked in a pane crop")
    }

    @Test func maskingTheStripPreservesTheLaunchImageMask() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: "chat", title: "secret-title")]), reveal: reveal)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        let launch = NSView(frame: pane.contentHost.bounds)
        pane.contentHost.addSubview(launch)
        pane.launchImageView = launch
        let mask = ScreenshotMask.read(window, rules: .app)
        let stripRect = pane.stripView.convert(pane.stripView.bounds, to: nil)
        let launchRect = launch.convert(launch.bounds, to: nil)
        #expect(stripRect.width > 0 && stripRect.height > 0)
        #expect(launchRect.width > 0 && launchRect.height > 0)
        #expect(mask.regions.contains(stripRect))
        #expect(mask.regions.contains(launchRect))
    }

    /// App pages are masked unless checked to show nothing secret: a new page is masked by default.
    @Test func appPagesAreMaskedUnlessListedAndHomeIsMasked() {
        #expect(!ScreenshotMask.shownAppPages.contains("cmux.agent"))
        #expect(!ScreenshotMask.shownAppPages.contains("cmux.passwords"))
        #expect(!ScreenshotMask.shownAppPages.contains("cmux.home-channels"))
        #expect(!ScreenshotMask.shownAppPages.contains("cmux.settings"))
        #expect(ScreenshotMask.covers(HomeSidebarView(frame: .zero)))
        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        let list = HomeSidebarView(frame: NSRect(x: 4, y: 4, width: 60, height: 60))
        fixture.plain.addSubview(list)
        #expect(ScreenshotMask.read(fixture.window, rules: .app).regions.contains(list.convert(list.bounds, to: nil)))
    }

    /// The allow path: a listed app page is not covered, and the web view it holds is not covered
    /// for being a web view (`Rules.app.isAppPage` and `read`'s `inAppPage`). Without this, a
    /// rename of the page host type would mask Files, Diff and Keybindings with no test failing.
    @Test func aListedAppPageAndItsWebViewAreNotCovered() throws {
        let listed = try #require(PageWebView(descriptor: .files, routes: []))
        #expect(ScreenshotMask.shownAppPages.contains(PageDescriptor.files.id))
        #expect(!ScreenshotMask.covers(listed), "a listed app page is shown")
        #expect(ScreenshotMask.Rules.app.isAppPage(listed), "a page view holds the app's own content")
        let unlisted = try #require(PageWebView(descriptor: PageDescriptor(id: "cmux.not-checked", resource: "files",
                                                                          namespaces: ["cmux.not-checked."]), routes: []))
        #expect(ScreenshotMask.covers(unlisted), "a page nobody checked is masked")

        // The page's own web view is reached through the page, so it is not masked on its own.
        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        listed.frame = NSRect(x: 8, y: 8, width: 80, height: 80)
        fixture.plain.addSubview(listed)
        let regions = ScreenshotMask.read(fixture.window, rules: .app).regions
        #expect(!regions.contains(listed.convert(listed.bounds, to: nil)), "the listed page itself is not masked")
        for web in listed.subviews.compactMap({ $0 as? WKWebView }) {
            #expect(!regions.contains(web.convert(web.bounds, to: nil)), "its web view is the page's own content")
        }
    }

    /// A native page tab (no PageWebView inside) is masked whole unless its page was checked: a
    /// Phone or Mac Screen frame, Passwords or a page nobody checked never reaches automation.
    @Test func aNativePageTabIsMaskedUnlessListed() throws {
        let phone = InternalPageView(key: "mask-phone", page: InternalPageID(rawValue: "phone"), content: NSView())
        let unchecked = InternalPageView(key: "mask-new", page: InternalPageID(rawValue: "not-checked"), content: NSView())
        let diff = InternalPageView(key: "mask-diff", page: InternalPageID(rawValue: "diff"), content: NSView())
        #expect(ScreenshotMask.covers(phone))
        #expect(ScreenshotMask.covers(unchecked), "a native page nobody checked is masked")
        #expect(!ScreenshotMask.covers(diff), "a listed native page is shown")
        // A web page tab is judged by its page view: a listed one is not masked for its host.
        let listed = try #require(PageWebView(descriptor: .files, routes: []))
        #expect(!ScreenshotMask.covers(InternalPageView(key: "mask-files", page: InternalPageID(rawValue: "unlisted-host"), content: listed)))

        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        phone.frame = NSRect(x: 8, y: 8, width: 80, height: 80)
        fixture.plain.addSubview(phone)
        #expect(ScreenshotMask.read(fixture.window, rules: .app).regions.contains(phone.convert(phone.bounds, to: nil)))
    }

    /// An area that moves between two readings may have shown its pixels between the two frames,
    /// so the capture refuses instead of masking only the frames it read.
    @Test func anAreaThatMovesBetweenReadingsIsUnsettled() {
        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        let sampler = ScreenshotMask.Sampler(window: fixture.window, rules: .app)
        defer { sampler.stop() }
        sampler.sample()
        #expect(sampler.mask.isSettled, "nothing moved")
        fixture.chrome.frame = fixture.chrome.frame.offsetBy(dx: -40, dy: 0)
        sampler.sample()
        sampler.stop()
        #expect(!sampler.mask.isSettled)
    }

    /// The screen lags the view tree: a page shown for one run loop turn while the capture
    /// runs, then hidden again before its end, is still masked (the mask is every reading's).
    @Test func aPageShownForOneTurnDuringTheCaptureIsStillMasked() {
        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        fixture.chrome.isHidden = true
        let sampler = ScreenshotMask.Sampler(window: fixture.window, rules: .app)
        defer { sampler.stop() }
        #expect(sampler.mask.regions.isEmpty)
        fixture.chrome.isHidden = false
        sampler.sample()
        fixture.chrome.isHidden = true
        sampler.stop()
        #expect(ScreenshotMask.read(fixture.window, rules: .app).regions.isEmpty)
        #expect(sampler.mask.regions.contains(fixture.chromeRect))
    }

    /// A web view outside any browser chrome (no app page holds it) is masked too, and a page
    /// whose pixels are not where its frame says (a transform or an animation) refuses the
    /// capture instead of masking the wrong place.
    @Test func aStrayWebViewIsMaskedAndAMovingPageIsUnsettled() {
        let fixture = fixture(onScreen: false)
        defer { fixture.close() }
        let stray = WKWebView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        fixture.plain.addSubview(stray)
        let mask = ScreenshotMask.read(fixture.window, rules: .app)
        #expect(mask.regions.contains(stray.convert(stray.bounds, to: nil)))
        #expect(mask.regions.contains(fixture.chromeRect), "a browser pane is masked whole, its toolbar included")
        #expect(mask.isSettled)
        fixture.chrome.pageArea.layer?.transform = CATransform3DMakeTranslation(12, 0, 0)
        #expect(!ScreenshotMask.read(fixture.window, rules: .app).isSettled)
    }

    /// A mask covers whole pixels and one more on each side at a fractional scale, so no pixel
    /// of what it covers blends into its edge.
    @Test func aMaskCoversWholePixelsAtAFractionalScale() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 1200,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(Self.red)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        let base = try #require(context.makeImage())
        // 1.5 pixels per point: x 15.3 to 45.75 and y 15.3 to 45.75 pixels.
        let rect = NSRect(x: 10.2, y: 10.2, width: 20.3, height: 20.3)
        let image = try #require(WindowImageLayer.composite(base: base, window: window, layers: [.mask(rect)]))
        let pixels = Pixels(image)
        for x in 14...46 { for y in 14...46 { #expect(Self.isMask(pixels.at(x: x, y: y)), "(\(x), \(y))") } }
        #expect(Self.isRed(pixels.at(x: 12, y: 30)))
        #expect(Self.isRed(pixels.at(x: 48, y: 30)))
        #expect(Self.isRed(pixels.at(x: 30, y: 48)))
    }

    /// Only a person's own run in the app gets raw pixels; a socket run claiming `user` does not,
    /// and neither does a run that names a caller (an app, an agent chat or a terminal gets the
    /// image), even one carrying `user` from the person's gesture inside it.
    @Test func onlyAPersonsRunInTheAppIsRaw() {
        var claimed = ActionInvocation(origin: .user)
        claimed.viaControlSocket = true
        #expect(!claimed.isPersonsOwnRun)
        #expect(ActionInvocation().isPersonsOwnRun)
        for origin in ActionOrigin.allCases where origin != .user {
            #expect(!ActionInvocation(origin: origin).isPersonsOwnRun, "\(origin)")
        }
        var app = ActionInvocation(origin: .user)
        app.callerApp = "com.example.sidebar-app"
        #expect(!app.isPersonsOwnRun)
        var chat = ActionInvocation(origin: .user)
        chat.callerAgentSession = "agent-1"
        #expect(!chat.isPersonsOwnRun)
        var terminal = ActionInvocation(origin: .user)
        terminal.callerTerminal = "term_1"
        #expect(!terminal.isPersonsOwnRun)
    }
}
