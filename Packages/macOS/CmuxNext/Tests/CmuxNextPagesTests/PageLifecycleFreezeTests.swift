import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// The page lifecycle's freeze and thaw on both engines (p13-webui-028): a page is hidden before it
/// freezes and thaws before it shows, a shown page refuses to freeze, Chromium gets one
/// `setFrozen` per freeze, and WebKit stays in its window, hidden, with its hidden-page throttling on.
/// Every step is a call in the test's turn: nothing sleeps or waits on a clock.
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

    /// The lifecycle's target for `view`; its hide picture encodes to nothing (these tests read freeze
    /// and thaw only).
    private func lifecycle(_ view: PageWebView) -> PageWebViewLifecycle {
        PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) })
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

    @Test func aChromiumPageIsHiddenThenFrozenOnceAndThawsBeforeItShows() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        tab.isHidden = true
        let target = lifecycle(view)
        let before = page.lifecycleSteps.count
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
        tab.isHidden = true
        let before = page.lifecycleSteps.count
        #expect(view.freezePage())
        tab.isHidden = false
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true), .frozen(false), .visible(true)])
    }

    @Test func aShownChromiumPageRefusesToFreeze() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        #expect(view.isShownInWindow)
        #expect(!lifecycle(view).freeze())
        #expect(!page.lifecycleSteps.contains(.frozen(true)))
    }

    /// The engine still counts the page visible (`SetPageFrozen` freezes hidden pages only): the
    /// freeze is refused, and a thaw sends nothing.
    @Test func aChromiumPageTheEngineDidNotFreezeIsNotThawed() async throws {
        let (view, page) = try await chromiumView()
        defer { finish(view) }
        page.freezes = false
        tab.isHidden = true
        let before = page.lifecycleSteps.count
        #expect(!view.freezePage())
        view.thawPage()
        #expect(Array(page.lifecycleSteps.dropFirst(before)) == [.visible(false), .frozen(true)])
    }

    // MARK: WebKit

    /// Whether every hidden-page throttling preference reads on, through the getter of each setter
    /// (`_setHiddenPageDOMTimerThrottlingEnabled:` reads as `_hiddenPageDOMTimerThrottlingEnabled`).
    private static func throttlingIsOn(_ preferences: WKPreferences) -> Bool {
        WKPreferences.hiddenPageThrottlingSetters.allSatisfy { setter in
            let property = String(setter.dropFirst("_set".count).dropLast())
            let getter = "_" + property.prefix(1).lowercased() + String(property.dropFirst())
            guard preferences.responds(to: NSSelectorFromString(getter)) else { return false }
            return preferences.value(forKey: getter) as? Bool == true
        }
    }

    /// Every throttling preference exists in this WebKit (a missing one would leave hidden pages
    /// at WebKit's default).
    @Test func thisWebKitHasEveryHiddenPageThrottlingPreference() {
        #expect(WKPreferences().enableHiddenPageThrottling() == WKPreferences.hiddenPageThrottlingSetters.count)
    }

    @Test func aWebKitPageStaysInItsWindowHiddenAndThrottledAndThawsBeforeItShows() throws {
        let view = try webKitView()
        defer { finish(view) }
        tab.isHidden = true
        let target = lifecycle(view)
        #expect(target.freeze())
        #expect(view.webKitView.isHidden)
        #expect(view.webKitView.window === window, "WebKit is not detached")
        #expect(Self.throttlingIsOn(view.webKitView.configuration.preferences))
        // The lifecycle's show thaws while the tab is still hidden.
        target.thaw()
        #expect(!view.webKitView.isHidden)
        #expect(!view.isShownInWindow)
        tab.isHidden = false
        #expect(view.isShownInWindow)
    }

    @Test func aWebKitPageShownWithoutAThawThawsBeforeItIsVisible() throws {
        let view = try webKitView()
        defer { finish(view) }
        tab.isHidden = true
        #expect(view.freezePage())
        tab.isHidden = false
        #expect(!view.webKitView.isHidden)
    }

    @Test func aShownWebKitPageRefusesToFreeze() throws {
        let view = try webKitView()
        defer { finish(view) }
        #expect(!view.freezePage())
        #expect(!view.webKitView.isHidden)
        view.thawPage()
        #expect(!view.webKitView.isHidden)
    }
}
