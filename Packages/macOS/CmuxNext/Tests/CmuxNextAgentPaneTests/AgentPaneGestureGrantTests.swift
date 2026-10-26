import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextInput

/// The agent panes' gesture grant through the app's one input tap (p04-input-017): one subscription
/// per window that holds a pane, not one app-wide monitor per pane. A key-down goes to the pane that
/// holds the first responder, a click to the pane under the pointer, an event in a Chromium page's
/// child window to the pane whose page is there, and to no other pane: with 50 panes in a window a
/// press costs one pane's check.
@Suite(.serialized)
@MainActor
struct AgentPaneGestureGrantTests {
    /// A pane that counts the presses routed to it. `field` takes the keyboard.
    final class Pane: NSView, AgentPaneGestureTarget {
        final class Field: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        let field = Field()
        var judged: [NSEvent.EventType] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            field.frame = bounds.insetBy(dx: 10, dy: 10)
            addSubview(field)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func judge(_ event: NSEvent, eventWindow: NSWindow?) { judged.append(event.type) }

        func ownsChildWindowPoint(_ point: CGPoint, eventWindow: NSWindow) -> Bool {
            guard let window, eventWindow.parent === window else { return false }
            return window.convertToScreen(convert(bounds, to: nil)).contains(point)
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
        let screenFrame = harness.window.convertToScreen(harness.panes[5].frame)
        let child = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        harness.window.addChildWindow(child, ordered: .above)
        child.orderFrontRegardless()
        harness.dispatch(try harness.mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: child))
        harness.dispatch(try harness.key(.keyDown, in: child))
        #expect(harness.panes[5].judged == [.leftMouseDown, .keyDown])
        #expect(harness.judgedTotal == 2, "a Chromium page's press reached another pane")
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

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func anAgentPaneSubscribesInAWindowAndLeavesTheTapWhenItCloses() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gesture-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body><button>Allow</button></body></html>".utf8).write(to: file)
        let tap = InputEventTap()
        let router = AgentPaneGestureRouter(input: tap)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), gestures: router))
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
