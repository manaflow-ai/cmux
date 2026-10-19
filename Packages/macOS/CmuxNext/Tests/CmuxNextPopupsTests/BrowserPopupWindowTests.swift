import AppKit
import CmuxNextBrowser
@testable import CmuxNextPopups
import Foundation
import Testing

/// Popup windows follow Chrome's `TYPE_POPUP` window on macOS (user,
/// 2026-10-13: "popup windows need parity with chrome"): an independent
/// window with all three traffic lights and the page title, a read-only
/// location bar, the requested page size, and no close on Escape or with
/// the opener.
@MainActor @Suite(.serialized) struct BrowserPopupWindowTests {
    // MARK: Geometry (Blink `create_window.cc`, `WindowSizer`, `AdjustToFit`)

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let opener = CGRect(x: 200, y: 100, width: 1000, height: 700)
    private let chrome: CGFloat = 62

    private func frame(_ request: BrowserPopupRequest, fallback: CGSize? = nil) -> CGRect {
        BrowserPopupWindowGeometry.frame(for: request, opener: opener, fallbackContent: fallback ?? opener.size,
                                         visibleFrame: screen, primaryHeight: 900, chromeHeight: chrome)
    }

    @Test func theRequestedSizeIsThePageSize() {
        let placed = frame(BrowserPopupRequest(size: CGSize(width: 500, height: 400)))
        #expect(placed.size == CGSize(width: 500, height: 400 + chrome), "the window adds its title bar and location bar")
    }

    @Test func aSizeBelowBlinksMinimumIsRaisedTo100() {
        let placed = frame(BrowserPopupRequest(size: CGSize(width: 40, height: 10)))
        #expect(placed.size == CGSize(width: 100, height: 100 + chrome))
    }

    @Test func withoutAPositionItOpens22PointsFromTheOpenersTopLeft() {
        let placed = frame(BrowserPopupRequest(size: CGSize(width: 500, height: 400)))
        #expect(placed.minX == opener.minX + 22)
        #expect(placed.maxY == opener.maxY - 22)
    }

    @Test func leftAndTopPlaceTheWindowsTopLeftCorner() {
        let placed = frame(BrowserPopupRequest(size: CGSize(width: 500, height: 400), origin: CGPoint(x: 300, y: 150)))
        #expect(placed.minX == 300)
        let top: CGFloat = 900 - 150
        #expect(abs(placed.maxY - top) < 0.001, "measured from the primary display's top")
    }

    @Test func chromiumsMadeUpCornerPositionCascadesFromTheOpener() {
        // Chromium reports the work area's top-left (0, 900 - 875) when the page gave no position.
        let made = BrowserPopupRequest(size: CGSize(width: 500, height: 400), origin: CGPoint(x: 0, y: 25))
        let request = BrowserPopupWindowGeometry.droppingChromiumDefaultOrigin(made, visibleFrame: screen, primaryHeight: 900)
        #expect(request.origin == nil)
        let placed = frame(request)
        #expect(placed.minX == opener.minX + 22)
        let given = BrowserPopupRequest(size: CGSize(width: 500, height: 400), origin: CGPoint(x: 300, y: 150))
        #expect(BrowserPopupWindowGeometry.droppingChromiumDefaultOrigin(given, visibleFrame: screen, primaryHeight: 900) == given)
    }

    @Test func aMissingSizeTakesTheOpenerWindowsSize() {
        let placed = frame(BrowserPopupRequest(size: .zero), fallback: CGSize(width: 800, height: 500))
        #expect(placed.size == CGSize(width: 800, height: 500 + chrome))
    }

    @Test func theWindowFitsTheVisibleScreenWithoutAMargin() {
        let tooLarge = frame(BrowserPopupRequest(size: CGSize(width: 4000, height: 3000)))
        #expect(tooLarge == screen, "shrunk to the work area, no margin (gfx::Rect::AdjustToFit)")
        let offRight = frame(BrowserPopupRequest(size: CGSize(width: 500, height: 400), origin: CGPoint(x: 1300, y: 150)))
        #expect(offRight.maxX == screen.maxX, "moved back inside, not re-centered")
        #expect(offRight.width == 500)
    }

    // MARK: Window

    private func makeOpener() -> NSWindow {
        let window = NSWindow(contentRect: opener, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func open(_ url: String, request: BrowserPopupRequest = BrowserPopupRequest(size: CGSize(width: 480, height: 360)))
        -> (BrowserPopupWindows, MockBrowserTab, BrowserPopupWindow, NSWindow) {
        let popups = BrowserPopupWindows()
        popups.ordersWindowsIn = false
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: url)))
        let opener = makeOpener()
        popups.open(tab, request: request, from: opener, openerKey: "tab_opener")
        return (popups, tab, popups.window(for: tab)!, opener)
    }

    @Test func aPopupIsAWindowOfItsOwnWithAllThreeTrafficLights() {
        let (popups, _, window, opener) = open("https://accounts.example.com/signin")
        defer { popups.closeAll() }
        #expect(window.parent == nil, "not a child of the opener's window")
        #expect(opener.childWindows?.contains(window) != true)
        #expect(!(window is NSPanel))
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let shown = window.standardWindowButton(button).map { !$0.isHidden } ?? false
            #expect(shown, "traffic light \(button.rawValue) shows")
        }
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.titleVisibility == .visible)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.isExcludedFromWindowsMenu, "listed in the Window menu like any browser window")
    }

    @Test func thePageGetsTheSizeItAskedFor() {
        let (popups, _, window, _) = open("https://example.com", request: BrowserPopupRequest(size: CGSize(width: 480, height: 360)))
        defer { popups.closeAll() }
        window.contentView?.layoutSubtreeIfNeeded()
        let page = window.page.contentView
        #expect(page.frame.size == CGSize(width: 480, height: 360))
    }

    @Test func theTitleIsThePageTitleElseTheAddress() {
        #expect(BrowserPopupWindow.title(for: BrowserTabState(url: URL(string: "https://a.example.com/x"), title: "Sign in")) == "Sign in")
        #expect(BrowserPopupWindow.title(for: BrowserTabState(url: URL(string: "https://www.example.com/login"), title: " ")) == "example.com/login")
        #expect(BrowserPopupWindow.title(for: BrowserTabState()) == "Untitled", "loads from this module's Popups table")
    }

    @Test func theTitleFollowsThePage() async throws {
        let (popups, tab, window, _) = open("https://accounts.example.com/signin")
        defer { popups.closeAll() }
        tab.simulate(.titleChanged("Sign in - Example"))
        try await waitUntil { window.title == "Sign in - Example" }
        #expect(window.title == "Sign in - Example")
    }

    @Test func theLocationBarShowsTheAddressReadOnly() async throws {
        let (popups, tab, window, _) = open("http://insecure.example.com/pay?id=1")
        defer { popups.closeAll() }
        tab.simulate(.securityChanged(.insecure))
        try await waitUntil { window.locationBar.displayedText == "http://insecure.example.com/pay?id=1" }
        #expect(window.locationBar.displayedText == "http://insecure.example.com/pay?id=1", "http:// stays, as in the omnibox")
        #expect(window.isToolbarShown)
        tab.load(URL(string: "https://www.example.com/done")!)
        try await waitUntil { window.locationBar.displayedText == "example.com/done" }
        #expect(window.locationBar.displayedText == "example.com/done")
    }

    @Test func fullscreenHidesTheLocationBar() {
        let (popups, _, window, _) = open("https://example.com")
        defer { popups.closeAll() }
        window.showToolbar(false)
        #expect(!window.isToolbarShown)
        window.showToolbar(true)
        #expect(window.isToolbarShown)
    }

    @Test func escapeStopsALoadAndNeverClosesThePopup() {
        let (popups, tab, window, _) = open("https://example.com")
        defer { popups.closeAll() }
        tab.completesNavigationsImmediately = false
        tab.load(URL(string: "https://example.com/slow")!)
        #expect(popups.handle(tab, .unhandledEscape))
        window.cancelOperation(nil)
        #expect(popups.owns(tab), "still open")
        #expect(!tab.isClosed)
        #expect(tab.commands.contains(.stop), "Escape stopped the load")
    }

    @Test func thePopupStaysOpenWhenItsOpenerWindowCloses() {
        let (popups, tab, _, opener) = open("https://example.com")
        defer { popups.closeAll() }
        opener.close()
        #expect(popups.owns(tab))
        #expect(!tab.isClosed)
    }

    @Test func windowCloseClosesThePopupAndItsPage() {
        let (popups, tab, _, _) = open("https://example.com")
        #expect(popups.handle(tab, .close))
        #expect(!popups.owns(tab))
        #expect(tab.isClosed)
    }

    @Test func aPopupsOwnPopupIsAnotherPopupWindowOfTheSameOpenerTab() throws {
        let (popups, tab, window, _) = open("https://example.com")
        defer { popups.closeAll() }
        let child = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/child")))
        #expect(popups.handle(tab, .openPopup(child, BrowserPopupRequest(size: CGSize(width: 300, height: 200)))))
        let nested = try #require(popups.window(for: child))
        #expect(nested !== window)
        #expect(nested.parent == nil)
        #expect(popups.openerKey(of: child) == "tab_opener")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
