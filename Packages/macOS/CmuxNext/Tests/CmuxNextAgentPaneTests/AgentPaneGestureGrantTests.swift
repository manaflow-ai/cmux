import AppKit
import CmuxNextDesign
import CmuxNextPagesTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextInput
import CmuxNextWakeups

/// The agent panes' gesture grant through the app's one input tap (p04-input-017): one subscription
/// per window that holds a pane, not one app-wide monitor per pane. A key-down goes to the pane that
/// holds the first responder, a click to the pane under the pointer, an event in a Chromium page's
/// child window to the shown pane whose page window it is, and to no other pane: with 50 panes in a
/// window a press costs one pane's check.
@Suite(.serialized)
@MainActor
struct AgentPaneGestureGrantTests {
    /// A pane that counts the presses routed to it. `field` takes the keyboard; `pageWindow` is the
    /// child window its page draws in, if any.
    final class Pane: NSView, AgentPaneGestureTarget {
        final class Field: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        let field = Field()
        var judged: [NSEvent.EventType] = []
        var pageWindow: NSWindow?
        var gestureNode: VisibilityNode?
        /// The router's child-window questions to this pane.
        var asked = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            field.frame = bounds.insetBy(dx: 10, dy: 10)
            addSubview(field)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func judge(_ event: NSEvent, eventWindow: NSWindow?) { judged.append(event.type) }

        func ownsChildWindow(_ eventWindow: NSWindow) -> Bool {
            asked += 1
            return eventWindow === pageWindow
        }
    }

    /// 50 panes in a 10 by 5 grid in one window, each attached to one router over one tap.
    final class Harness {
        let tap = InputEventTap()
        let router: AgentPaneGestureRouter
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var panes: [Pane] = []

        init(count: Int = 50) {
            // A synthesized event finds its window (`NSEvent.window`, which the tap's window scope
            // reads for a child window) through NSApp.
            _ = NSApplication.shared
            router = AgentPaneGestureRouter(input: tap)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
            window.contentView = root
            for index in 0..<count {
                let pane = Pane(frame: NSRect(x: (index % 10) * 100, y: (index / 10) * 100, width: 100, height: 100))
                root.addSubview(pane)
                router.attach(pane, to: window)
                panes.append(pane)
            }
            window.orderFrontRegardless()
        }

        /// A borderless child window over `frame` (window coordinates), as a Chromium page's.
        func childWindow(over frame: NSRect) -> NSWindow {
            let child = NSWindow(contentRect: window.convertToScreen(frame), styleMask: [.borderless], backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            child.orderFrontRegardless()
            return child
        }

        func close() {
            for child in window.childWindows ?? [] { child.orderOut(nil) }
            window.orderOut(nil)
        }

        var judgedTotal: Int { panes.reduce(0) { $0 + $1.judged.count } }

        /// The middle of pane `index`, in window coordinates.
        func center(of index: Int) -> CGPoint { CGPoint(x: panes[index].frame.midX, y: panes[index].frame.midY) }

        /// Sends `event` through the tap as CmuxApplication does.
        func dispatch(_ event: NSEvent) {
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        func key(_ type: NSEvent.EventType, in target: NSWindow? = nil) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: (target ?? window).windowNumber, context: nil, characters: "a",
                                          charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, in target: NSWindow? = nil) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: (target ?? window).windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    @Test func fiftyPanesInAWindowHoldOneSubscription() {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.router.subscribedWindowCount == 1)
        #expect(harness.tap.subscriberCount(.key, stage: .intercept) == 1, "one key subscription per window, not one per pane")
        #expect(harness.tap.subscriberCount(.button, stage: .intercept) == 1, "one button subscription per window, not one per pane")
        #expect(harness.tap.subscriberCount(.key, stage: .observe) == 0)
    }

    @Test func aKeyDownCallsOnlyThePaneThatHoldsTheKeyboard() throws {
        let harness = Harness()
        defer { harness.close() }
        try #require(harness.window.makeFirstResponder(harness.panes[17].field))
        harness.dispatch(try harness.key(.keyDown))
        #expect(harness.panes[17].judged == [.keyDown])
        #expect(harness.judgedTotal == 1, "with 50 panes a key-down reached \(harness.judgedTotal) pane handlers")
        #expect(harness.router.judgedCount == 1)

        harness.dispatch(try harness.key(.keyUp))
        #expect(harness.judgedTotal == 1, "a key-up is not a press")

        try #require(harness.window.makeFirstResponder(nil))
        harness.dispatch(try harness.key(.keyDown))
        #expect(harness.judgedTotal == 1, "a key with no pane focused went to a pane")
    }

    @Test func aClickCallsOnlyThePaneUnderThePointer() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.dispatch(try harness.mouse(.leftMouseDown, at: harness.center(of: 33)))
        harness.dispatch(try harness.mouse(.leftMouseUp, at: harness.center(of: 33)))
        harness.dispatch(try harness.mouse(.rightMouseDown, at: harness.center(of: 2)))
        #expect(harness.panes[33].judged == [.leftMouseDown], "the mouse-up is not a press")
        #expect(harness.panes[2].judged == [.rightMouseDown])
        #expect(harness.judgedTotal == 2)

        harness.panes[40].isHidden = true
        harness.dispatch(try harness.mouse(.leftMouseDown, at: harness.center(of: 40)))
        #expect(harness.panes[40].judged.isEmpty, "a hidden pane took a click")
        #expect(harness.judgedTotal == 2)
    }

    @Test func aPressInAChildWindowGoesToThePaneWhosePageIsThere() throws {
        let harness = Harness()
        defer { harness.close() }
        let child = harness.childWindow(over: harness.panes[5].frame)
        harness.panes[5].pageWindow = child
        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: child))
        harness.dispatch(try harness.key(.keyDown, in: child))
        #expect(harness.panes[5].judged == [.leftMouseDown, .keyDown])
        #expect(harness.judgedTotal == 2, "a Chromium page's press reached another pane")
    }

    /// Tabs of one pane keep their pages in the window, hidden, at the same frame. A press in the
    /// shown tab's page window goes to that tab, never to a hidden tab attached before it at the
    /// same place; a press in a hidden tab's page window goes to no pane.
    @Test func aPressInAPageWindowGoesToTheShownTabNotAHiddenOneAtTheSamePlace() throws {
        let harness = Harness(count: 0)
        defer { harness.close() }
        let frame = NSRect(x: 100, y: 100, width: 300, height: 200)
        let hidden = Pane(frame: frame)
        let shown = Pane(frame: frame)
        for pane in [hidden, shown] {
            harness.window.contentView?.addSubview(pane)
            harness.router.attach(pane, to: harness.window)
            pane.pageWindow = harness.childWindow(over: frame)
        }
        let tab = VisibilityNode(root: "pane", own: .visible)
        hidden.gestureNode = VisibilityNode("tab:hidden", own: .hidden, parent: tab)
        shown.gestureNode = VisibilityNode("tab:shown", own: .visible, parent: tab)
        let shownPage = try #require(shown.pageWindow)
        let hiddenPage = try #require(hidden.pageWindow)

        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 100), in: shownPage))
        harness.dispatch(try harness.key(.keyDown, in: shownPage))
        #expect(shown.judged == [.leftMouseDown, .keyDown], "the shown tab's page lost its press")
        #expect(hidden.judged.isEmpty, "a hidden tab at the same place took the shown tab's press")

        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 100), in: hiddenPage))
        #expect(hidden.judged.isEmpty && shown.judged.count == 2, "a hidden tab's page window granted a press")
    }

    /// p06-scheduler-220: 40 hidden tabs and the shown one share one pane's place, each with its page
    /// window there. A press in the shown page asks one pane, not 41: a hidden tab node is skipped in O(1).
    @Test func fortyHiddenTabsAndOneShownAskOnePanePerPress() throws {
        let harness = Harness(count: 0)
        defer { harness.close() }
        let frame = NSRect(x: 100, y: 100, width: 300, height: 200)
        let pane = VisibilityNode(root: "pane", own: .visible)
        var tabs: [Pane] = []
        var nodes: [VisibilityNode] = []
        for index in 0..<41 {
            let tab = Pane(frame: frame)
            let node = VisibilityNode("tab:\(index)", own: index == 40 ? .visible : .hidden, parent: pane)
            tab.gestureNode = node
            nodes.append(node)
            harness.window.contentView?.addSubview(tab)
            harness.router.attach(tab, to: harness.window)
            tab.pageWindow = harness.childWindow(over: frame)
            tabs.append(tab)
        }
        let shown = tabs[40]
        let shownPage = try #require(shown.pageWindow)

        harness.dispatch(try harness.key(.keyDown, in: shownPage))
        #expect(shown.judged == [.keyDown])
        #expect(tabs.reduce(0) { $0 + $1.asked } == 1, "a key-down asked \(tabs.reduce(0) { $0 + $1.asked }) panes")
        #expect(tabs.reduce(0) { $0 + $1.judged.count } == 1)

        // Selecting tab 0: its node shows and the old one hides, and the next press follows.
        nodes[40].set(.hidden)
        nodes[0].set(.visible)
        let page0 = try #require(tabs[0].pageWindow)
        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 100), in: page0))
        #expect(tabs[0].judged == [.leftMouseDown])
        #expect(shown.judged == [.keyDown], "the tab hidden since took the press")
        harness.dispatch(try harness.key(.keyDown, in: shownPage))
        #expect(shown.judged == [.keyDown], "a hidden tab's page window granted a press")
    }

    @Test func anotherWindowsPressesAreNotHeard() throws {
        let harness = Harness()
        defer { harness.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }
        harness.dispatch(try harness.mouse(.leftMouseDown, at: harness.center(of: 0), in: other))
        #expect(harness.judgedTotal == 0)
    }

    @Test func theSubscriptionEndsWithTheWindowsLastPane() {
        let harness = Harness(count: 3)
        defer { harness.close() }
        harness.router.detach(harness.panes[0])
        harness.router.detach(harness.panes[1])
        #expect(harness.tap.subscriberCount(.key, stage: .intercept) == 1, "the window still holds a pane")
        harness.router.detach(harness.panes[2])
        #expect(harness.router.subscribedWindowCount == 0)
        #expect(harness.tap.subscriberCount(.key, stage: .intercept) == 0)
        #expect(harness.tap.subscriberCount(.button, stage: .intercept) == 0)
    }

    @Test func aPaneMovedToAnotherWindowIsHeardThereOnly() throws {
        let harness = Harness(count: 1)
        defer { harness.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }
        let pane = harness.panes[0]
        other.contentView = pane
        harness.router.attach(pane, to: other)
        #expect(harness.router.subscribedWindowCount == 1, "the old window's subscription outlived its last pane")
        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: other))
        #expect(pane.judged == [.leftMouseDown])
    }

    // MARK: The agent pane itself

    /// An agent pane owns a child window only when it is its own Chromium page's window and the pane
    /// shows: another pane's page window at the same place, or its own while it is hidden, is not its.
    @Test func anAgentPaneOwnsOnlyItsOwnPageWindowAndOnlyWhileShown() async throws {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        var views: [AgentPaneView] = []
        var pageWindows: [NSWindow] = []
        defer {
            views.forEach { $0.close() }
            pageWindows.forEach { $0.close() }
            window.close()
        }
        try await addChromiumPanes(to: [root, root], page: file, into: &views)
        for view in views {
            let page = try #require(view.chromiumPage as? FakeChromiumPage)
            let child = NSWindow(contentRect: window.convertToScreen(root.bounds), styleMask: [.borderless], backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            page.pageWindow = child
            pageWindows.append(child)
        }
        let hidden = views[0], shown = views[1]
        hidden.isHidden = true

        #expect(shown.ownsChildWindow(pageWindows[1]))
        #expect(!shown.ownsChildWindow(pageWindows[0]), "a pane owned another tab's page window at the same place")
        #expect(!hidden.ownsChildWindow(pageWindows[1]), "a hidden pane owned the shown tab's page window")
        #expect(!hidden.ownsChildWindow(pageWindows[0]), "a hidden pane owned its own page window")
    }

    /// A screen that is not active is a hidden view, but its panes' tab nodes stay visible (pane nodes
    /// do not follow screen hiding yet, p06-scheduler-023), and a Chromium page window is matched by
    /// parent and place (`CEFTab.isPageWindow`). A pane on a hidden screen at the shown pane's rect,
    /// with a visible node, must not own the shown pane's page window: the router would grant it the
    /// press first.
    @Test func aPaneOnAHiddenScreenWithAVisibleNodeDoesNotOwnTheShownPanesPageWindow() async throws {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let screens = (0..<2).map { _ in NSView(frame: root.bounds) }
        screens.forEach { root.addSubview($0) }
        var views: [AgentPaneView] = []
        let pageWindow = NSWindow(contentRect: window.convertToScreen(root.bounds), styleMask: [.borderless], backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        defer {
            views.forEach { $0.close() }
            pageWindow.close()
            window.close()
        }
        try await addChromiumPanes(to: screens, page: file, into: &views)
        window.addChildWindow(pageWindow, ordered: .above)
        for (index, view) in views.enumerated() {
            view.followAppearance(DesignSettings.shared.signals, node: VisibilityNode(root: "pane:\(index)", own: .visible))
            // Both pages sit at the same rect over the same parent: a page window matched by place is both's.
            let page = try #require(view.chromiumPage as? FakeChromiumPage)
            page.pageWindow = pageWindow
        }
        let hidden = views[0], shown = views[1]
        screens[0].isHidden = true
        #expect(hidden.gestureNode?.effective == .visible, "the case needs the hidden screen's pane node to stay visible")

        #expect(shown.ownsChildWindow(pageWindow))
        #expect(!hidden.ownsChildWindow(pageWindow), "a pane on a hidden screen owned the shown pane's page window")
    }

    /// One agent pane per container, at its bounds, with a fake Chromium host; returns once every
    /// pane's page shows in Chromium. Appends to `views` as it makes them, so the caller closes each.
    private func addChromiumPanes(to containers: [NSView], page file: URL, into views: inout [AgentPaneView]) async throws {
        var made: [AgentPaneView] = []
        for container in containers {
            let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                                  webUI: .agentPaneTestHost(chromium: FakeChromiumHosting()), gestures: .testing()))
            views.append(view)
            made.append(view)
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
        }
        let deadline = Date().addingTimeInterval(5)
        while !made.allSatisfy({ $0.debugShowsChromium }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(made.allSatisfy({ $0.debugShowsChromium }))
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func anAgentPaneSubscribesInAWindowAndLeavesTheTapWhenItCloses() throws {
        let file = try #require(AgentPageTestRoot.page)
        let tap = InputEventTap()
        let router = AgentPaneGestureRouter(input: tap)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentPaneTestHost(),
                                              gestures: router))
        #expect(tap.subscriberCount(.button, stage: .intercept) == 0, "a pane in no window costs the tap nothing")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        #expect(tap.subscriberCount(.button, stage: .intercept) == 1)

        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 150), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tap.dispatching { _ = tap.deliverIntercepts(click) }
        #expect(router.judgedCount == 1, "a click on the pane's page did not reach the pane's gesture check")

        view.close()
        #expect(tap.subscriberCount(.button, stage: .intercept) == 0, "a closed pane left its window's subscription")
        #expect(tap.subscriberCount(.key, stage: .intercept) == 0)
    }
}
