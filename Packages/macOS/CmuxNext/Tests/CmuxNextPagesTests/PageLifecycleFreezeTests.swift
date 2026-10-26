import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// The page lifecycle's freeze and thaw on both engines (p13-webui-028): a page is hidden before it
/// freezes and thaws before it shows, a shown page refuses to freeze, Chromium gets one
/// `setFrozen` per freeze, and WebKit stays in its window, hidden, with all of its hidden-page
/// throttling on until the thaw gives back what it had. Every step is a call in the test's turn:
/// nothing sleeps or waits on a clock.
@MainActor @Suite(.serialized)
struct PageLifecycleFreezeTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-freeze", resource: "page-freeze", processGroup: .viewer, namespaces: [])
    private let window: NSWindow
    /// The tab's content view: the content lifecycle hides and shows it, as a pane hides a tab.
    private let tab: NSView

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-freeze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        tab = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(tab)
    }

    private func finish(_ view: PageWebView) {
        view.close()
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// A Chromium page in the tab, once its page reached the host.
    private func chromiumView() async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        view.frame = tab.bounds
        tab.addSubview(view)
        return (view, try #require(hosting.made.first))
    }

    /// A WebKit page in the tab.
    private func webKitView() throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        view.frame = tab.bounds
        tab.addSubview(view)
        return view
    }

    // MARK: Chromium

    /// The whole sequence from the tab's hide: AppKit's hide reaches the engine (`viewDidHide`), then
    /// the one freeze; the thaw, then AppKit's show. Nothing but the hide tells the page it is hidden.
    @Test func aChromiumPageIsHiddenThenFrozenOnceAndThawsBeforeItShows() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        let before = page.lifecycleSteps.count
        tab.isHidden = true
        let target = PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) })
        #expect(target.freeze())
        #expect(target.freeze(), "a frozen page answers frozen again")
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true)])
        // The lifecycle's show thaws in its own turn, then the tab reveals the page.
        target.thaw()
        target.thaw()
        tab.isHidden = false
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true), .frozen(false), .visible(true)])
    }

    /// A reveal that skipped the lifecycle's show still thaws the page before it becomes visible.
    @Test func aChromiumPageShownWithoutAThawThawsBeforeItIsVisible() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        let before = page.lifecycleSteps.count
        tab.isHidden = true
        #expect(view.freezePage())
        tab.isHidden = false
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true), .frozen(false), .visible(true)])
    }

    @Test func aShownChromiumPageRefusesToFreeze() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        #expect(view.isShownInWindow)
        #expect(!PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) }).freeze())
        #expect(!page.lifecycleSteps.contains(.frozen(true)))
    }

    /// The engine still counts the page visible (`SetPageFrozen` freezes hidden pages only): the
    /// freeze is refused, and a thaw sends nothing.
    @Test func aChromiumPageTheEngineDidNotFreezeIsNotThawed() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        page.freezes = false
        let before = page.lifecycleSteps.count
        tab.isHidden = true
        #expect(!view.freezePage())
        view.thawPage()
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true)])
    }

    /// The frozen Chromium page's browser ends while the tab is hidden: the page reopens in WebKit
    /// frozen (hidden in its window, fully throttled), so the lifecycle's frozen state stays true.
    @Test func aFrozenChromiumPageThatFallsBackToWebKitStaysFrozenInWebKit() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        tab.isHidden = true
        #expect(view.freezePage())
        page.onEvent?(.ended)
        #expect(view.engineDecision.engine == .webKit)
        #expect(view.webView.isHidden)
        #expect(view.webView.configuration.preferences.hiddenPageThrottling == .full)
        #expect(view.freezePage())
        view.thawPage()
        #expect(!view.webView.isHidden)
    }

    // MARK: WebKit

    /// Close to macOS WebKit's defaults, and neither all on nor all off, so a thaw that restores
    /// differs from one that turns everything off or keeps the freeze's values.
    private static let mixed = WebKitHiddenPageThrottling(domTimers: true, domTimersAutoIncrease: false, processSuppression: true)

    /// Every throttling preference exists in this WebKit, and the setter changes each one: from all
    /// off on a fresh WKPreferences to all on, then to a mix.
    @Test func theThrottlingSetterChangesEveryPreferenceThisWebKitHas() {
        let preferences = WKPreferences()
        #expect(preferences.setHiddenPageThrottling(.off) == 3)
        #expect(preferences.hiddenPageThrottling == .off)
        #expect(preferences.setHiddenPageThrottling(.full) == 3)
        #expect(preferences.hiddenPageThrottling == .full)
        preferences.setHiddenPageThrottling(Self.mixed)
        #expect(preferences.hiddenPageThrottling == Self.mixed)
    }

    @Test func aWebKitPageStaysInItsWindowHiddenAndThrottledAndThawsBeforeItShows() throws {
        let view = try webKitView()
        defer { finish(view) }
        let preferences = view.webView.configuration.preferences
        preferences.setHiddenPageThrottling(.off)
        tab.isHidden = true
        let target = PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) })
        #expect(target.freeze())
        #expect(view.webView.isHidden)
        #expect(view.webView.window === window, "WebKit is not detached")
        #expect(preferences.hiddenPageThrottling == .full)
        // The lifecycle's show thaws while the tab is still hidden.
        target.thaw()
        #expect(!view.webView.isHidden)
        #expect(!view.isShownInWindow)
        tab.isHidden = false
        #expect(view.isShownInWindow)
    }

    /// The thaw gives the page back the throttling it had: a page the lifecycle keeps running while
    /// hidden (recently visible, loading, a keep reason) is not throttled like a frozen one.
    @Test func aThawedWebKitPageGetsBackTheThrottlingItHadBeforeTheFreeze() throws {
        let view = try webKitView()
        defer { finish(view) }
        let preferences = view.webView.configuration.preferences
        for before in [WebKitHiddenPageThrottling.off, Self.mixed] {
            preferences.setHiddenPageThrottling(before)
            tab.isHidden = true
            #expect(view.freezePage())
            #expect(preferences.hiddenPageThrottling == .full)
            view.thawPage()
            #expect(preferences.hiddenPageThrottling == before)
            tab.isHidden = false
        }
    }

    @Test func aWebKitPageShownWithoutAThawThawsBeforeItIsVisible() throws {
        let view = try webKitView()
        defer { finish(view) }
        view.webView.configuration.preferences.setHiddenPageThrottling(Self.mixed)
        tab.isHidden = true
        #expect(view.freezePage())
        tab.isHidden = false
        #expect(!view.webView.isHidden)
        #expect(view.webView.configuration.preferences.hiddenPageThrottling == Self.mixed)
    }

    @Test func aShownWebKitPageRefusesToFreeze() throws {
        let view = try webKitView()
        defer { finish(view) }
        #expect(!view.freezePage())
        #expect(!view.webView.isHidden)
        view.thawPage()
        #expect(!view.webView.isHidden)
    }
}
