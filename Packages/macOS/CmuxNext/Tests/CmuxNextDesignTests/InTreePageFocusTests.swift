import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The window's focus rule for in-tree pages (plans/cmux-next/in-tree-pages.md, Focus): a page view becomes the
/// window's first responder only for the person's input aimed at it, a focus-model move to its pane, a routed move
/// naming it, or cmux's own grant. Chromium focusing its page by itself is refused. A fake page (a container with a
/// view inside, as Chromium's `RenderWidgetHostViewCocoa` sits in the fork's `WebContentsViewCocoa`) stands in.
@MainActor @Suite(.closesItsWindows, .serialized) struct InTreePageFocusTests {
    /// The page container, as `CEFInTreePageView` is to the browser.
    /// It names no pane (the browser cannot); the window's `paneOf` says where it shows, as the app reads it from its
    /// view tree.
    final class FakeContainer: NSView, InTreePageContainer {
        var inTreeCensus: InTreePageCensus { InTreePageCensus(contentInWindow: window != nil, widgetDrawing: 0) }
    }

    /// The page's own view: takes the keyboard, like Chromium's.
    final class FakePageView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A text field elsewhere in the window: where the person types before the page asks.
    final class Field: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    struct Fixture {
        let window: NSWindow
        let container: FakeContainer
        let page: FakePageView
        let field: Field
        /// The pane the window's view tree puts the container in.
        let pane: String
    }

    private static func fixture(pane: String = "p1") -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = FakeContainer(frame: NSRect(x: 400, y: 0, width: 400, height: 500))
        let page = FakePageView(frame: container.bounds)
        container.addSubview(page)
        let field = Field(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(container)
        window.makeFirstResponder(field)
        return Fixture(window: window, container: container, page: page, field: field, pane: pane)
    }

    private static func refuses(_ f: Fixture, event: NSEvent? = nil, applies: Bool = false, focused: String? = nil,
                                route: NSResponder? = nil, active: Bool = true) -> Bool {
        InTreePageFocus.shared.refuses(f.page, in: f.window, event: event, focusModelApplies: applies,
                                       focusedPane: { focused }, paneOf: { $0 === f.container ? f.pane : nil },
                                       routeTarget: route, isActive: active)
    }

    private static func press(_ window: NSWindow, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test func aPageFocusingItselfIsRefused() {
        let f = Self.fixture()
        defer { f.window.close() }
        let refused = InTreePageFocus.shared.refused
        #expect(Self.refuses(f), "Chromium focusing its page with no input and no route was let through")
        #expect(InTreePageFocus.shared.refused == refused + 1)
        #expect(InTreePageFocus.shared.lastRefusal == "no input event or focus route")
    }

    @Test func aClickOnThePageLetsItTakeTheKeys() throws {
        let f = Self.fixture()
        defer { f.window.close() }
        let event = try #require(Self.press(f.window, at: NSPoint(x: 600, y: 250)))
        #expect(!Self.refuses(f, event: event))
    }

    @Test func aClickElsewhereDoesNot() throws {
        let f = Self.fixture()
        defer { f.window.close() }
        let event = try #require(Self.press(f.window, at: NSPoint(x: 100, y: 250)))
        #expect(Self.refuses(f, event: event))
        #expect(InTreePageFocus.shared.lastRefusal == "input event aimed elsewhere")
    }

    @Test func aRouteNamingThePageLetsItIn() {
        let f = Self.fixture()
        defer { f.window.close() }
        #expect(!Self.refuses(f, route: f.page))
        #expect(Self.refuses(f, route: f.field), "a route naming another view let the page in")
    }

    @Test func theFocusModelMovingToThePagesPaneLetsItIn() {
        let f = Self.fixture(pane: "p1")
        defer { f.window.close() }
        #expect(!Self.refuses(f, applies: true, focused: "p1"))
        #expect(Self.refuses(f, applies: true, focused: "p2"), "the focus model's move to another pane let this page in")
        #expect(Self.refuses(f, applies: false, focused: "p1"), "the focused pane alone, outside the model's move, let the page in")
    }

    @Test func cmuxsOwnGrantLetsItIn() {
        let f = Self.fixture()
        defer { f.window.close() }
        let allowed = InTreePageFocus.shared.granting(f.container) { !Self.refuses(f) }
        #expect(allowed)
        #expect(Self.refuses(f), "the grant outlived its call")
    }

    @Test func aKeyWhileThePageHoldsTheKeysMovesInsideIt() throws {
        let f = Self.fixture()
        defer { f.window.close() }
        let inner = FakePageView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        f.page.addSubview(inner)
        _ = InTreePageFocus.shared.granting(f.container) { f.window.makeFirstResponder(f.page) }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: f.window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(!InTreePageFocus.shared.refuses(inner, in: f.window, event: key, focusModelApplies: false,
                                                focusedPane: { nil }, paneOf: { _ in nil }, routeTarget: nil, isActive: true))
    }

    @Test func otherViewsAndTheModeOffAreNeverJudged() {
        let f = Self.fixture()
        defer { f.window.close() }
        #expect(!InTreePageFocus.shared.refuses(f.field, in: f.window, event: nil, focusModelApplies: false,
                                                focusedPane: { nil }, paneOf: { _ in nil }, routeTarget: nil, isActive: true))
        #expect(!Self.refuses(f, active: false))
    }

    @Test func aPageViewIsFoundByItsContainerNotItsClass() {
        let f = Self.fixture()
        defer { f.window.close() }
        let deep = NSView()
        f.page.addSubview(deep)
        #expect(InTreePageFocus.container(of: deep) === f.container)
        #expect(InTreePageFocus.container(of: f.field) == nil)
        #expect(InTreePageFocus.containers(in: f.window).map { ObjectIdentifier($0) } == [ObjectIdentifier(f.container)])
    }

    @Test func theSwitchFollowsEnvironmentThenFileThenTag() {
        #expect(InTreePages.decide(fileOverride: false, tag: "in-tree-pages", environment: ["CMUX_IN_TREE_PAGES": "1"]) == (true, "environment"))
        #expect(InTreePages.decide(fileOverride: true, tag: nil, environment: ["CMUX_IN_TREE_PAGES": "0"]) == (false, "environment"))
        #expect(InTreePages.decide(fileOverride: false, tag: "in-tree-pages", environment: [:]) == (false, "file"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "in-tree-pages-2", environment: [:]) == (true, "tag"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "other", environment: [:]) == (false, "default"))
        #expect(InTreePages.decide(fileOverride: nil, tag: nil, environment: [:]) == (false, "default"))
    }

    @Test func anEngineWithoutTheCallsTurnsTheModeOff() {
        defer { InTreePages.shared.setForTesting(requested: false) }
        InTreePages.shared.setForTesting(requested: true)
        #expect(InTreePages.shared.isActive && InTreePages.shared.status == "pending")
        InTreePages.shared.engineResolved(.unsupported("api 34 < 36"))
        #expect(!InTreePages.shared.isActive)
        #expect(InTreePages.shared.status == "unsupported_fork: api 34 < 36")
    }
}
