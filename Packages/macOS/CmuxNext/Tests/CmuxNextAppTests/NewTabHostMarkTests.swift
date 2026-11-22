import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// The host's own mark that input went to a New Tab page (`AgentPaneHostTouch`). A page says that it was touched
/// only when it runs a request, which is after it got the input. Until then the host would take the page for an
/// untouched one, and an untouched New Tab page can go to another tab. So the host sets a mark at the place that
/// sees the input first, and a marked page counts as a touched one (`AgentPaneModel.userTouched`).
///
/// - A letter that the page's view sees with the keyboard in the page sets the mark.
/// - A New Tab key that the page's view sees first, and that the key router then runs as the app's action, leaves
///   no mark: the key was the app's. The view cannot know that when it sees the key, so the mark is set and then
///   taken back before the action runs.
/// - A letter and then a New Tab key: the mark stays. Only the mark that the app's own key set is taken back.
/// - A mouse-down on the page sets the mark. A mouse-down at the place of a page view that is hidden sets none: a
///   page view that a pane keeps and does not show has the pane's frame too, and gets no input.
/// - The start of a scroll over the page sets the mark, and so does a tick of a wheel with no phases. A scroll
///   beside the page, and an event of a scroll that is under way, set none.
/// - A paste and a file drop that the page's web view reports set the mark.
/// - A letter that the key router queues for a page whose field is not ready sets the mark, and the store then has
///   no idle page for a pane that leaves that tab.
///
/// The app and its setup are those of `NewTabHoldMovesItsPageTests`: each row starts with one New Tab key, so the
/// pane shows a New Tab tab with a page view that got no input. A key or a mouse event goes to the page's view
/// only (`AgentPaneView.judge`, which the app's event monitor calls before the event goes on); no page gets it, so
/// no page reports it. A scroll goes to the app's host marks (`AgentPaneHostMarks.scrolled`, which the app's input
/// monitor calls for each scroll event), with the window and the place that a real event has.
///
/// Limits. The package's tests have no Chromium host, so each page view is a WebKit one. The rows do not prove that
/// AppKit calls the monitors before a page gets an event. A paste and a file drop set the mark in the reports of the
/// page's web view: their row calls those reports, and sends no paste and no drag. The app's dictation sets the mark
/// in the page view's own hook; no row sends one. The row of a queued letter calls the key router's queue step for
/// the letter; `LetterBetweenTwoNewTabKeysTests` has the whole way of a letter between 2 New Tab keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabHostMarkTests {
    typealias Rows = NewTabHoldMovesItsPageTests

    /// The page view of the New Tab tab that the pane shows, with the keyboard, and its window. The page has no
    /// mark at the row's start.
    static func shownPage(_ services: AppServices, _ pane: PaneController) throws -> (AgentPaneView, NSWindow) {
        let shown = try #require(pane.currentTabKey, "setup: the pane shows no tab")
        let page = try #require(services.agentTabs.existingView(shown), "setup: the shown New Tab tab has no page view")
        try #require(!page.model.hostTouch.marked, "setup: the page has the host's mark before the row's input, by \(page.model.hostTouch.by ?? "?")")
        return (page, try Rows.keyboard(to: page, in: pane))
    }

    /// The middle of the web view of `page`, in the coordinates of its window.
    static func middle(of page: AgentPaneView) -> CGPoint {
        page.webView.convert(CGPoint(x: page.webView.bounds.midX, y: page.webView.bounds.midY), to: nil)
    }

    /// A left mouse-down at `point` of `window`.
    static func mouseDown(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        let made = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        return try #require(made, "setup: no mouse event could be made")
    }

    /// What the mark of `page` says, for a row's print.
    static func state(_ page: AgentPaneView) -> String {
        "the host's mark = \(page.model.hostTouch.marked), by \(page.model.hostTouch.by ?? "none"); the page counts as touched = \(page.model.userTouched)"
    }

    @Test func aLetterThatThePagesViewSeesMarksThePage() async throws {
        try await Rows.row("cn-host-mark-letter") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            page.judge(try Rows.keyDown("a", code: 0, command: false, in: window), eventWindow: window)
            print("NewTabHostMarkTests: a letter with the keyboard in the page: \(Self.state(page))")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == "key", "a letter that the page's view saw set no mark of a key: \(Self.state(page))")
            #expect(page.model.userTouched, "a page with the host's mark does not count as a touched one")
        }
    }

    @Test func aNewTabKeyThatTheRouterRunsLeavesNoMark() async throws {
        try await Rows.row("cn-host-mark-app-key") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            let strip = pane.orderedIDs.count
            let event = try Rows.keyDown("t", code: 17, command: true, in: window)
            page.judge(event, eventWindow: window)
            let between = page.model.hostTouch.marked
            let router = services.keyRouter
            let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            try #require(took, "setup: the key router passed the New Tab key on")
            try #require(pane.orderedIDs.count == strip + 1, "setup: the New Tab key added \(pane.orderedIDs.count - strip) tabs to the strip, want 1")
            await NewTabPageAtItsFrameTests.frame(services)
            print("NewTabHostMarkTests: a New Tab key that the page's view saw first: the mark between the view and the router = \(between); after the router ran the key: \(Self.state(page))")
            #expect(between, "the page's view saw a key-down with the keyboard in the page and set no mark: the row then proves nothing about the router")
            #expect(!page.model.hostTouch.marked, "the New Tab key left the host's mark on the page whose view saw it first: \(Self.state(page))")
        }
    }

    @Test func aLetterBeforeTheNewTabKeyKeepsItsMark() async throws {
        try await Rows.row("cn-host-mark-letter-then-app-key") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            page.judge(try Rows.keyDown("a", code: 0, command: false, in: window), eventWindow: window)
            let strip = pane.orderedIDs.count
            let event = try Rows.keyDown("t", code: 17, command: true, in: window)
            page.judge(event, eventWindow: window)
            let router = services.keyRouter
            let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            try #require(took, "setup: the key router passed the New Tab key on")
            try #require(pane.orderedIDs.count == strip + 1, "setup: the New Tab key added \(pane.orderedIDs.count - strip) tabs to the strip, want 1")
            await NewTabPageAtItsFrameTests.frame(services)
            print("NewTabHostMarkTests: a letter, then a New Tab key that the router ran: \(Self.state(page))")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == "key", "the New Tab key took back the mark that a letter set before it: \(Self.state(page))")
        }
    }

    @Test func aMouseDownOnThePageMarksItAndOneAtAHiddenPageDoesNot() async throws {
        try await Rows.row("cn-host-mark-mouse") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            let click = try Self.mouseDown(at: Self.middle(of: page), in: window)
            page.isHidden = true
            page.judge(click, eventWindow: window)
            let hidden = page.model.hostTouch.marked
            page.isHidden = false
            page.judge(click, eventWindow: window)
            print("NewTabHostMarkTests: a mouse-down at the place of the page: while the page view was hidden, the mark = \(hidden); while it showed: \(Self.state(page))")
            #expect(!hidden, "a mouse-down at the place of a hidden page view set the host's mark")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == "mouse", "a mouse-down on the page set no mark of the mouse: \(Self.state(page))")
        }
    }

    @Test(arguments: ["the start of a gesture", "a wheel tick"]) func aScrollOverThePageMarksIt(scroll: String) async throws {
        try await Rows.row("cn-host-mark-scroll-\(scroll == "a wheel tick" ? "tick" : "gesture")") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            let marks = services.personInput.hostMarks
            let frame = page.convert(page.bounds, to: nil), middle = Self.middle(of: page)
            let beside = frame.minX >= 8 ? CGPoint(x: frame.minX - 4, y: frame.midY) : CGPoint(x: frame.midX, y: frame.maxY + 4)
            let start = LayoutScrollModifierTests.event(dy: -12, phase: scroll == "a wheel tick" ? nil : .began)
            marks.scrolled(start, in: window, at: beside)
            let atBeside = page.model.hostTouch.marked
            marks.scrolled(LayoutScrollModifierTests.event(dy: -12, phase: .changed), in: window, at: middle)
            let underWay = page.model.hostTouch.marked
            marks.scrolled(start, in: window, at: middle)
            // What AppKit's hit test gives at the page's middle, for a row that fails: the mark goes to the agent page above it.
            var chain: [String] = [], hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(middle, from: nil) ?? middle) }
            while let view = hit, chain.count < 12 {
                chain.append(String(describing: type(of: view)))
                hit = view.superview
            }
            print("NewTabHostMarkTests: \(scroll): a scroll beside the page, the mark = \(atBeside); an event of a scroll under way over the page, the mark = \(underWay); the scroll's start over the page: \(Self.state(page))")
            #expect(!atBeside, "a scroll beside the page set the host's mark")
            #expect(!underWay, "an event of a scroll that is under way set the host's mark: only a start does a hit test")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == "scroll", "a scroll over the page set no mark of a scroll: \(Self.state(page)); the views at the page's middle, from the hit one up: \(chain)")
        }
    }

    /// The row calls the report of the page's web view: the one that the web view's own `paste(_:)` calls before
    /// WebKit's paste, and the one that its `performDragOperation(_:)` calls with the files of the drag. No pasteboard
    /// is read and nothing goes to the page. A view on the page host (the app's default) has the 2 reports on its
    /// page object, which gives them to its web view; a view on the old host has them on its own web view. The app
    /// gives the 2 hosts one pair of reports (`AgentPaneView.installContextMenu`), and the row takes the pair of
    /// the host that the view has.
    @Test(arguments: ["paste", "drop"]) func aPasteOrAFileDropThatThePagesWebViewReportsMarksThePage(input: String) async throws {
        try await Rows.row("cn-host-mark-\(input)") { services, pane, _, _ in
            let (page, _) = try Self.shownPage(services, pane)
            let old = page.webView as? AgentPaneWKWebView
            let host = page.page != nil ? "the page host" : "the old host"
            if input == "paste" {
                let report = try #require(page.page?.onPaste ?? old?.onPaste, "setup: the page's web view has no report of a paste (\(host))")
                report()
            } else {
                let report = try #require(page.page?.onFilesDropped ?? old?.onFilesDropped, "setup: the page's web view has no report of a file drop (\(host))")
                report([FileManager.default.temporaryDirectory.appending(path: "cn-host-mark-drop.txt")])
            }
            print("NewTabHostMarkTests: a \(input) that the page's web view reported (\(host)): \(Self.state(page))")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == input, "a \(input) that the page's web view reported set no mark of a \(input): \(Self.state(page))")
            #expect(page.model.userTouched, "a page with the host's mark of a \(input) does not count as a touched one")
        }
    }

    /// The key router queues a letter for the shown page, whose field is not ready (`KeyRouter.typesAhead`, the step
    /// that the router runs for a letter that no key hold takes). The queue owes its text to the page's view. Want:
    /// the page has the host's mark, and the store has no idle page for a pane that leaves the tab, so the next
    /// New Tab tab does not take the view with the letter.
    @Test func aLetterThatTheRouterQueuesForThePageMarksIt() async throws {
        try await Rows.row("cn-host-mark-type-ahead") { services, pane, _, _ in
            let (page, window) = try Self.shownPage(services, pane)
            try #require(pane.currentTabKey != nil, "setup: the pane shows no tab")
            let tabs = services.agentTabs, router = services.keyRouter
            try #require(tabs.idlePage(leaving: pane) === page, "setup: the store has no idle page for a pane that leaves the untouched tab: the row then proves nothing")
            let queued = router.typesAhead(try Rows.keyDown("a", code: 0, command: false, in: window), in: window)
            defer { router.dropTypeAhead() }
            let focus = services.windowController(showing: pane).map { String(describing: $0.focus.state.resolved) } ?? "no window controller"
            try #require(queued && router.typeAhead.text == "a",
                         "setup: the key router did not queue the letter for the page. The page's field is ready: \(page.inputReadiness.isReady); the focus: \(focus)")
            let idle = tabs.idlePage(leaving: pane)
            print("NewTabHostMarkTests: a letter in the key router's queue for the shown page: \(Self.state(page)); the store has an idle page for a pane that leaves the tab: \(idle != nil)")
            #expect(page.model.hostTouch.marked && page.model.hostTouch.by == "type-ahead", "a letter that the key router queued for the page set no mark of the queue: \(Self.state(page))")
            #expect(idle == nil, "the store gives the page view with a queued letter to the next tab: the letter would be typed into another tab")
        }
    }
}
