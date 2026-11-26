import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// Views window mode (approach 3 of the Chromium integration study, a prototype): the fork shows each in-tree page as a
/// Views child of the cmux window, outside its container, and names the container on the page's view. The window's
/// focus rules find the page's pane through that name. A fake page stands in for Chromium's `WebContentsViewCocoa` in
/// Views' content view, inside the window's slot.
@MainActor @Suite(.closesItsWindows, .serialized) struct ViewsWindowTests {
    final class FakeContainer: NSView, InTreePageContainer {
        var shows = false
        var inTreeCensus: InTreePageCensus { InTreePageCensus(contentInWindow: window != nil, widgetDrawing: 0) }
        var hostsPage: Bool { !subviews.isEmpty || shows }
    }

    final class FakePageView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    struct Fixture {
        let window: NSWindow
        let container: FakeContainer
        let slot: ViewsWindowSlotView
        let page: FakePageView
        let content: FakePageView
    }

    /// The container on the right half, the page over it in the slot, as the fork places it; `content` is the page's
    /// `RenderWidgetHostViewCocoa`.
    private static func fixture() -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = window.contentView!
        let container = FakeContainer(frame: NSRect(x: 400, y: 0, width: 400, height: 500))
        root.addSubview(container)
        let slot = ViewsWindowSlotView(frame: root.bounds)
        root.addSubview(slot)
        let bridged = NSView(frame: slot.bounds)
        slot.addSubview(bridged)
        let page = FakePageView(frame: container.frame)
        bridged.addSubview(page)
        let content = FakePageView(frame: page.bounds)
        page.addSubview(content)
        let key = unsafeBitCast(sel_registerName("cmuxViewsContainer"), to: UnsafeRawPointer.self)
        objc_setAssociatedObject(page, key, container, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.shows = true
        return Fixture(window: window, container: container, slot: slot, page: page, content: content)
    }

    @Test func aPageViewFindsTheContainerTheForkNamed() {
        let f = Self.fixture()
        defer { f.window.close() }
        #expect(InTreePages.viewsContainer(of: f.content) === f.container)
        #expect(InTreePages.anchor(of: f.content) === f.container)
        #expect(InTreePageFocus.container(of: f.content) === f.container)
        #expect(InTreePages.anchor(of: f.slot) === f.slot, "a view outside a page stood in for something else")
        #expect(InTreePageFocus.containers(in: f.window).map { ObjectIdentifier($0) } == [ObjectIdentifier(f.container)])
    }

    @Test func theGeometryReportFollowsThePageIntoTheSlot() throws {
        let f = Self.fixture()
        defer { f.window.close() }
        #expect(InTreePages.viewsPage(of: f.container) === f.page)
        let report = InTreePageGeometry.report(f.container)
        let place = try #require(report["views_window"] as? [String: Any], "the report read the empty container")
        #expect(report["fits"] as? Bool == true)
        #expect(place["superviews"] as? [String] == ["NSView", NSStringFromClass(ViewsWindowSlotView.self)])
        f.page.frame.origin.x -= 20
        #expect(InTreePageGeometry.report(f.container)["fits"] as? Bool == false, "a page off its pane fit")
    }

    @Test func theSlotTakesOnlyThePagesClicks() {
        let f = Self.fixture()
        defer { f.window.close() }
        let root = f.window.contentView!
        #expect(f.slot.identifier?.rawValue == InTreePages.viewsWindowSlotIdentifier)
        #expect(root.hitTest(NSPoint(x: 600, y: 250)) === f.content)
        #expect(root.hitTest(NSPoint(x: 100, y: 250)) === root, "the empty slot took a click meant for the window's content")
    }

    @Test func aClickOnThePageIsAimedAtItsContainer() throws {
        let f = Self.fixture()
        defer { f.window.close() }
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 600, y: 250), modifierFlags: [],
                                                    timestamp: 0, windowNumber: f.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(InTreePageFocus.event(press, isAimedAt: f.container, in: f.window))
        #expect(!InTreePageFocus.shared.refuses(f.content, in: f.window, event: press, focusModelApplies: false,
                                                 focusedPane: { nil }, paneOf: { _ in nil }, routeTarget: nil, isActive: true))
    }

    @Test func theSlotGoesRightAboveTheContentThatHoldsThePage() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = window.contentView!
        let content = NSView(frame: root.bounds)
        let container = FakeContainer(frame: NSRect(x: 400, y: 0, width: 400, height: 500))
        content.addSubview(container)
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        root.addSubview(content)
        root.addSubview(sidebar)
        #expect(ViewsWindowSlotView.install(over: FakeContainer(frame: .zero)) == nil, "a view in no window got a slot")
        let slot = ViewsWindowSlotView.install(over: container)
        #expect(root.subviews.map { ObjectIdentifier($0) } == [content, slot!, sidebar].map { ObjectIdentifier($0) })
        #expect(slot?.frame == root.bounds)
        #expect(ViewsWindowSlotView.install(over: container) === slot, "a second page made a second slot")
    }

    @Test func aPageViewStandsInForItsContainer() {
        let f = Self.fixture()
        defer { f.window.close() }
        #expect(f.content.inTreeAnchor === f.container)
        #expect(f.container.inTreeAnchor === f.container)
    }

    @Test(arguments: [
        (nil as String?, [:] as [String: String], false),
        ("views-window", [:], true),
        ("views-window-2", [:], true),
        ("itp-rs-views-window", [:], true),
        ("itp-rs-bench", [:], false),
        ("in-tree-pages", [:], false),
        ("views-window", ["CMUX_NEXT_VIEWS_WINDOW": "0"], false),
        (nil, ["CMUX_NEXT_VIEWS_WINDOW": "1"], true),
    ])
    func theSwitchFollowsTheEnvironmentThenTheTag(tag: String?, environment: [String: String], on: Bool) {
        #expect(InTreePages.viewsWindowRequested(tag: tag, environment: environment) == on)
        if on {
            let decided = InTreePages.decide(fileOverride: false, tag: tag, environment: environment)
            #expect(decided.0 && decided.1 == "views-window", "views window mode ran without in-tree pages")
        }
    }

    /// Chromium's widget window class, and a cmux window the fork adopted: it answers `isKind(of:)` for that class.
    final class FakeWidgetWindow: NSWindow {}
    final class AdoptedWindow: NSWindow {
        nonisolated override func isKind(of aClass: AnyClass) -> Bool { aClass === FakeWidgetWindow.self || super.isKind(of: aClass) }
    }

    @Test func anAdoptedWindowIsNotOneOfChromiumsOwn() {
        let frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        let adopted = AdoptedWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let chromium = FakeWidgetWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let plain = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        for window in [adopted, chromium, plain] { window.isReleasedWhenClosed = false }
        defer { for window in [adopted, chromium, plain] { window.close() } }
        #expect(InTreePages.isViewsWindowAdopted(adopted, widgetClass: FakeWidgetWindow.self))
        #expect(!InTreePages.isReally(adopted, kindOf: FakeWidgetWindow.self), "the guard would close cmux's window")
        #expect(InTreePages.isReally(chromium, kindOf: FakeWidgetWindow.self))
        #expect(!InTreePages.isViewsWindowAdopted(chromium, widgetClass: FakeWidgetWindow.self))
        #expect(!InTreePages.isViewsWindowAdopted(plain, widgetClass: FakeWidgetWindow.self))
        #expect(!InTreePages.isViewsWindowAdopted(adopted, widgetClass: nil))
    }
}
