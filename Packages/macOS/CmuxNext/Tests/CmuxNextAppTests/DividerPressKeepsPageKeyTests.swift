import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE P0 7 cause M1 (px-col-drag-2-s1r, cmux21 120 Hz 1x, build fe0d956f): with a Chromium page holding the key, a
/// divider press made the shell window key (`DividerMouseCatcherView.forward` -> `ShellWindow.sendEvent` ->
/// `FirstClickPolicy` -> `makeKey`). `-[NSThemeFrame _windowChangedKeyState]` then redrew every control of the window:
/// 101 view layouts, an 18.9 ms mouse-down frame, a missed refresh. The page also lost the key, so the press moved the
/// focus. Chrome's rule: a splitter is not focusable; a press there starts the drag and the focused content keeps the
/// focus (the page and the splitter share one key window there).
///
/// The rule here, through the window's own `sendEvent` (the path the catcher panels forward to): while the window's own
/// child window holds the key, a divider press asks for no key change, starts the drag, and lays out at most
/// `pressLayouts` views in its turn; the drag moves the divider and the release ends it. A press on a pane still makes
/// the window key (`FirstClickPolicy`). Test windows are never key, so the app's key state comes in through the
/// window's press router (`WindowPressRouter.appKeyState`) and its key requests are counted (`makeKey`).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct DividerPressKeepsPageKeyTests {
    typealias Counts = KeyResizeLayoutsPerFrameTests
    /// Views a divider press may lay out in its own turn (its band's look; no window pass).
    static let pressLayouts = 4

    struct Rig {
        let probe: LayoutWorkProbe
        let page: NSWindow
        let keyRequests: () -> Int

        init() {
            probe = LayoutWorkProbe(.columns([
                LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            ]), size: CGSize(width: 1200, height: 800), focused: "p1")
            probe.settle()
            // A Chromium page: a child window of the shell window, holding the key.
            let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered,
                                defer: true)
            page.isReleasedWhenClosed = false
            probe.window.addChildWindow(page, ordered: .above)
            self.page = page
            let window = probe.window
            window.presses.appKeyState = { [weak page, weak window] in
                AppKeyState(keyWindow: page, mainWindow: window, isActive: true, isModal: false)
            }
            final class Box { var count = 0 }
            let box = Box()
            window.presses.makeKey = { _ in box.count += 1 }
            keyRequests = { box.count }
        }

        func close() {
            probe.window.removeChildWindow(page)
            page.close()
            probe.close()
        }

        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            probe.window.sendEvent(probe.event(type, point))
        }
    }

    @Test func aDividerPressWhileThePageHoldsTheKeyStartsTheDragAndMovesNoKey() throws {
        LayoutPassGuard.shared.install()
        let rig = Rig()
        defer { rig.close() }
        let handle = try #require(rig.probe.screen.dividerViews[.split("x")], "no split handle in \(rig.probe.screen.dividerViews.keys)")
        let start = rig.probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        let responder = rig.probe.window.firstResponder
        let lineBefore = handle.frame.midX

        // The window's own pass (the theme frame) waits from the rig's setup: it runs before the press is counted.
        rig.probe.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let calls = Counts.calls()
        rig.send(.leftMouseDown, start)
        rig.probe.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let pressTurn = Counts.since(calls)
        let laid = pressTurn.values.reduce(0, +)
        for step in 1...6 {
            rig.send(.leftMouseDragged, CGPoint(x: start.x + 10 * CGFloat(step), y: start.y))
            rig.probe.settle()
        }
        rig.send(.leftMouseUp, CGPoint(x: start.x + 60, y: start.y))
        rig.probe.settle()

        #expect(rig.keyRequests() == 0, "the divider press asked to make the shell window key \(rig.keyRequests())x: the page loses the key")
        let responderAfter = String(describing: rig.probe.window.firstResponder)
        #expect(rig.probe.window.firstResponder === responder, "the press moved the first responder: \(String(describing: responder)) -> \(responderAfter)")
        #expect(laid <= Self.pressLayouts, "the press's turn laid out \(laid) views: [\(Counts.text(pressTurn))]")
        #expect(handle.frame.midX - lineBefore > 30, "the drag moved the divider \(handle.frame.midX - lineBefore) pt of 60")
    }

    /// A press on a pane (not a divider) still acts at once: the window is made key first, as before.
    @Test func aPanePressWhileThePageHoldsTheKeyStillMakesTheWindowKey() throws {
        let rig = Rig()
        defer { rig.close() }
        let host = try #require(rig.probe.screen.dividerViews[.split("x")])
        let point = rig.probe.screen.convert(CGPoint(x: host.frame.minX - 200, y: host.frame.midY), to: nil)
        rig.send(.leftMouseDown, point)
        rig.send(.leftMouseUp, point)
        #expect(rig.keyRequests() == 1, "a pane press made \(rig.keyRequests()) key requests")
    }

    /// A first click into a window of an inactive app keeps AppKit's rule (it activates the window; the divider takes
    /// the first mouse, as Chrome's content view does): no key request of ours. AppKit does not deliver a synthesized
    /// press to a window that is not on screen, so this rig cannot see AppKit start the drag; it checks the key only.
    @Test func aDividerPressInAnInactiveAppGoesToAppKit() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.probe.window.presses.appKeyState = { [weak page = rig.page, weak window = rig.probe.window] in
            AppKeyState(keyWindow: page, mainWindow: window, isActive: false, isModal: false)
        }
        let handle = try #require(rig.probe.screen.dividerViews[.split("x")])
        let start = rig.probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        rig.send(.leftMouseDown, start)
        rig.send(.leftMouseUp, start)
        #expect(rig.keyRequests() == 0)
    }

    /// A divider that leaves the window mid-drag (a socket or an agent closes its pane) keeps its press: the rest of the
    /// drags, force-click stages and the release stay with the router until the release. AppKit never got the press
    /// (the router took it), so its mouse-down view is an earlier press's view (a terminal); a drag or a release that
    /// fell through to `super.sendEvent` would reach that view with no mouseDown (a selection start, a mouse report).
    @Test func aDividerThatLeavesMidDragKeepsItsPressUntilTheRelease() throws {
        let rig = Rig()
        defer { rig.close() }
        let window = rig.probe.window
        let handle = try #require(rig.probe.screen.dividerViews[.split("x")])
        let start = rig.probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        rig.send(.leftMouseDown, start)
        #expect(window.presses.willSend(rig.probe.event(.leftMouseDragged, CGPoint(x: start.x + 10, y: start.y)), in: window),
                "the router did not take the drag of its own press")
        handle.removeFromSuperview()
        let lateDrag = rig.probe.event(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y))
        #expect(window.presses.willSend(lateDrag, in: window), "a drag after the divider left fell through to AppKit's stale mouse-down view")
        let release = rig.probe.event(.leftMouseUp, CGPoint(x: start.x + 20, y: start.y))
        #expect(window.presses.willSend(release, in: window), "the release after the divider left fell through to AppKit's stale mouse-down view")
        // After the release the router holds nothing: the next drag (of an AppKit press) goes to AppKit.
        #expect(!window.presses.willSend(rig.probe.event(.leftMouseDragged, start), in: window), "the router kept a press after its release")
        #expect(rig.keyRequests() == 0)
    }

    /// Only a page window keeps the key through a divider press. A key-capable child panel (the group-editor bubble, the
    /// screenshot section overlay) dismisses when it loses the key; a divider press closes it as before: the window
    /// is made key first (`FirstClickPolicy`), and AppKit gets the press.
    @Test func aDividerPressWhileAChildPanelHoldsTheKeyMakesTheWindowKey() throws {
        let rig = Rig()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        rig.probe.window.addChildWindow(panel, ordered: .above)
        defer {
            rig.probe.window.removeChildWindow(panel)
            panel.close()
            rig.close()
        }
        rig.probe.window.presses.appKeyState = { [weak panel, weak window = rig.probe.window] in
            AppKeyState(keyWindow: panel, mainWindow: window, isActive: true, isModal: false)
        }
        let handle = try #require(rig.probe.screen.dividerViews[.split("x")])
        let start = rig.probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        let routed = rig.probe.window.presses.willSend(rig.probe.event(.leftMouseDown, start), in: rig.probe.window)
        #expect(!routed, "the router took a divider press while a child panel held the key: the panel keeps the key")
        #expect(rig.keyRequests() == 1, "a divider press with a child panel key made \(rig.keyRequests()) key requests (want 1)")
    }

    /// A window a page opens over itself (DevTools, a page popup: a page window's child) keeps the key too.
    @Test func aDividerPressWhileAPagesOwnChildHoldsTheKeyMovesNoKey() throws {
        let rig = Rig()
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        rig.page.addChildWindow(popup, ordered: .above)
        defer {
            rig.page.removeChildWindow(popup)
            popup.close()
            rig.close()
        }
        rig.probe.window.presses.appKeyState = { [weak popup, weak window = rig.probe.window] in
            AppKeyState(keyWindow: popup, mainWindow: window, isActive: true, isModal: false)
        }
        let handle = try #require(rig.probe.screen.dividerViews[.split("x")])
        let start = rig.probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        rig.send(.leftMouseDown, start)
        rig.send(.leftMouseUp, start)
        #expect(rig.keyRequests() == 0, "a divider press with the page's popup key made \(rig.keyRequests()) key requests")
    }

    /// The sidebar's resize edge is a splitter too: its press while the page holds the key moves no key and drags.
    @Test func aSidebarEdgePressWhileThePageHoldsTheKeyMovesNoKey() throws {
        let sidebarTests = SidebarResizeAbovePageTests()
        let (window, root) = sidebarTests.root()
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        window.addChildWindow(page, ordered: .above)
        defer {
            window.removeChildWindow(page)
            page.close()
            window.close()
        }
        window.presses.appKeyState = { [weak page, weak window] in
            AppKeyState(keyWindow: page, mainWindow: window, isActive: true, isModal: false)
        }
        var keyRequests = 0
        window.presses.makeKey = { _ in keyRequests += 1 }
        let handle = try sidebarTests.handle(in: root)
        let band = handle.convert(handle.bounds, to: nil)
        let start = CGPoint(x: band.midX, y: band.midY)
        let widthBefore = root.sidebar.model.width
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y))
        send(.leftMouseUp, CGPoint(x: start.x + 40, y: start.y))
        #expect(keyRequests == 0, "the sidebar edge press asked to make the window key \(keyRequests)x")
        #expect(root.sidebar.model.width > widthBefore + 20, "the drag resized the sidebar: \(widthBefore) -> \(root.sidebar.model.width)")
    }
}
