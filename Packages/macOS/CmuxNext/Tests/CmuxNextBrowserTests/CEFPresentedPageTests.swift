import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Presented pages (InTreePages.Presentation.presented; cef-helper-app-DESIGN.md 3.3, 3.7 and 4, in process), without
/// Chromium: a fake fork and fake shim calls record every call at the shim boundary.
///
/// In-tree pages (fork API 36) put Chromium's page view into cmux's window while Chromium kept a second, headless
/// widget window for the same page, and every Chromium subsystem that reads state from a window disagreed between
/// the two (layer geometry drift, occlusion scans, key-window focus, compositor teardown on hide, resize commit sync,
/// full screen HasFocus), each its own patch. Presented pages keep exactly one Chromium window per page, its own,
/// detached (headless, never ordered in, never key) from its attach on; cmux's page view shows its context and is its
/// only input surface. These tests hold that contract: the page window detaches once and never comes back, the page
/// view hosts the context, input reaches the shim in page coordinates, and focus makes no window key.
@MainActor
@Suite(.closesItsWindows) struct CEFPresentedPageTests {
    /// The fork's hosting calls: a context for every page, and every detach and attach.
    final class FakeFork {
        private(set) var detaches: [(browser: Int32, on: Bool)] = []
        private(set) var hostingCalls: [(browser: Int32, on: Bool)] = []
        var acceptsDetach = true
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, on in
                hostingCalls.append((browser, on))
                return on ? 7 : 0
            }, setResizeSync: { _, _ in true }, setDetachedHosting: { [self] browser, on in
                detaches.append((browser, on))
                return acceptsDetach
            })
        }
        var record: [String] { detaches.map { "\($0.browser):\($0.on ? "detach" : "attach")" } }
    }

    /// The shim's presented-page calls.
    final class FakeShim {
        private(set) var mice: [(browser: Int32, mouse: ChromiumPageInput.Mouse)] = []
        private(set) var wheels: [(browser: Int32, wheel: ChromiumPageInput.Wheel)] = []
        private(set) var keys: [(browser: Int32, key: ChromiumPageInput.Key)] = []
        private(set) var edits: [(browser: Int32, command: ChromiumPageInput.Edit)] = []
        private(set) var focus: [(browser: Int32, focused: Bool)] = []
        var calls: CEFPresentedCalls {
            CEFPresentedCalls(sendMouse: { [self] in mice.append(($0, $1)) }, sendWheel: { [self] in wheels.append(($0, $1)) },
                              sendKey: { [self] in keys.append(($0, $1)) }, edit: { [self] in edits.append(($0, $1)) },
                              setPageFocus: { [self] in focus.append(($0, $1)) })
        }
    }

    /// Keeps each test's hosting alive (the page view holds its input weakly, as in the app the host view holds both).
    final class Keep { var hostings: [CEFLayerHosting] = [] }

    let fork = FakeFork()
    let shim = FakeShim()
    let keep = Keep()
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    /// The pane's host view, inset in the window so window and page coordinates differ.
    let host = NSView(frame: NSRect(x: 100, y: 50, width: 400, height: 300))

    init() {
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(host)
    }

    /// A presented page of browser 4 over `host`, its context hosted.
    func presentedPage(presented: Bool = true) throws -> (CEFLayerHosting, CEFHostedPageView) {
        var turn: [@MainActor @Sendable () -> Void] = []
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }, remoteRoot: { _ in nil }) },
                                      holdsFocus: { false }, afterCommit: { $0() }, afterFrameShown: { $0() })
        hosting.view = host
        keep.hostings.append(hosting)
        hosting.pageWindowCreated(browser: 4, fork: fork.fork, presented: presented ? shim.calls : nil)
        for block in turn { block() }
        let page = try #require(hosting.page, "SETUP: the page is not hosted")
        // A test window is never key: the page view reads its window as key, as the app's shown window is.
        page.windowIsKey = { _ in true }
        return (hosting, page)
    }

    // MARK: One Chromium window, detached for good

    @Test func aPresentedPageWindowDetachesWhenItsContextIsHostedAndNeverAttaches() throws {
        let (hosting, page) = try presentedPage()
        #expect(fork.record == ["4:detach"], "the page window must leave the cmux window as soon as its pixels are hosted")
        #expect(hosting.presents && hosting.isDetached)
        #expect(page.contextID == 7, "the page view hosts the page window's context")
        // Every motion and window change the child-window path attaches for.
        hosting.resizeMotion(active: true)
        hosting.resizeMotion(active: false)
        hosting.windowLiveResize(active: true)
        hosting.windowLiveResize(active: false)
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: false)
        hosting.windowDidChange()
        hosting.pageShown(browser: 4)
        #expect(!hosting.pageTakesFocus(), "a presented page has no window to bring back for a focus grant")
        var granted = false
        hosting.pageAppeared(windowInWindow: false) { granted = true }
        #expect(!hosting.holdsFirstFrame(), "no first-frame hold: no window is ordered in for a presented page")
        _ = granted
        #expect(fork.record == ["4:detach"], "a presented page window attached again: \(fork.record)")
        #expect(hosting.isDetached)
    }

    @Test func aRefusedDetachIsRetriedAtTheNextShow() throws {
        fork.acceptsDetach = false
        let (hosting, _) = try presentedPage()
        #expect(!hosting.isDetached && hosting.detachOwed)
        fork.acceptsDetach = true
        hosting.pageShown(browser: 4)
        #expect(hosting.isDetached && !hosting.detachOwed)
        #expect(fork.record == ["4:detach", "4:detach"])
    }

    /// The other modes are unchanged: a child-window page view takes no input, and its window attaches after a motion.
    @Test func aChildWindowPageViewTakesNoInput() throws {
        let (hosting, page) = try presentedPage(presented: false)
        #expect(!hosting.presents && page.input == nil)
        let center = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: window.contentView)
        #expect(window.contentView?.hitTest(center) !== page, "a child-window page's view took the mouse from its window")
        #expect(!page.acceptsFirstResponder)
        hosting.resizeMotion(active: true)
        hosting.resizeMotion(active: false)
        #expect(fork.record == ["4:detach", "4:attach"])
    }

    // MARK: The page view is the input surface

    @Test func thePageViewIsTheHitTargetWhereThePageShowsPixels() throws {
        let (hosting, page) = try presentedPage()
        let center = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: window.contentView)
        #expect(window.contentView?.hitTest(center) === page)
        #expect(page.acceptsFirstResponder && page.acceptsFirstMouse(for: nil))
        // The New Tab page is a hole: the host view under it takes the press there.
        hosting.pageHole = .whole
        #expect(window.contentView?.hitTest(center) !== page)
    }

    @Test func aClickReachesTheShimInPageCoordinates() throws {
        let (_, page) = try presentedPage()
        // 30 points from the page's left edge, 40 from its top.
        let inWindow = host.convert(NSPoint(x: 30, y: host.bounds.height - 40), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [.shift], timestamp: 5,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: 5.1,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 0))
        page.mouseDown(with: down)
        page.mouseUp(with: up)
        try #require(shim.mice.count == 2)
        let press = shim.mice[0]
        #expect(press.browser == 4)
        #expect(press.mouse.x == 30 && press.mouse.y == 40, "page coordinates: \(press.mouse.x), \(press.mouse.y)")
        #expect(press.mouse.phase == .down && press.mouse.button == 0 && press.mouse.clickCount == 2)
        #expect(NSEvent.ModifierFlags(rawValue: UInt(press.mouse.modifierFlags)).contains(.shift))
        #expect(shim.mice[1].mouse.phase == .up)
        // The press made the page view its window's first responder: the page has the keyboard.
        #expect(window.firstResponder === page)
        #expect(shim.focus.map(\.focused) == [true])
    }

    @Test func rightAndOtherButtonsAndMovesReachTheShim() throws {
        let (_, page) = try presentedPage()
        let point = host.convert(NSPoint(x: 10, y: 10), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        page.rightMouseDown(with: try event(.rightMouseDown))
        page.rightMouseUp(with: try event(.rightMouseUp))
        page.otherMouseDown(with: try event(.otherMouseDown))
        page.mouseMoved(with: try event(.mouseMoved))
        page.mouseDragged(with: try event(.leftMouseDragged))
        page.mouseExited(with: try event(.mouseMoved))
        #expect(shim.mice.map(\.mouse.button) == [2, 2, 1, 0, 0, 0])
        #expect(shim.mice.map(\.mouse.phase) == [.down, .up, .down, .move, .move, .exit])
        #expect(shim.mice[3].mouse.clickCount == 0, "a move carries no click count")
        #expect(shim.mice.allSatisfy { $0.mouse.x == 10 && $0.mouse.y == Int32(host.bounds.height) - 10 })
    }

    @Test func aScrollReachesTheShimWithItsPhases() throws {
        let (_, page) = try presentedPage()
        let point = CGPoint(x: 300, y: 200)  // global display coordinates do not matter: the event's window location does
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0))
        cg.location = point
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(NSEvent.Phase.began.rawValue))
        let event = try #require(NSEvent(cgEvent: cg))
        page.scrollWheel(with: event)
        try #require(shim.wheels.count == 1)
        let wheel = shim.wheels[0].wheel
        #expect(shim.wheels[0].browser == 4)
        #expect(wheel.phase == 2, "began is CMUX_RP_PHASE_BEGAN (2): \(wheel.phase)")
        #expect(wheel.dy != 0)
        #expect(ChromiumPageInput.wheelPhase([.changed]) == 3 && ChromiumPageInput.wheelPhase([.ended]) == 4)
        #expect(ChromiumPageInput.wheelPhase([.mayBegin]) == 1 && ChromiumPageInput.wheelPhase([.cancelled]) == 5)
        #expect(ChromiumPageInput.wheelPhase([]) == 0)
    }

    @Test func keysTheRouterLeftReachTheShim() throws {
        let (_, page) = try presentedPage()
        #expect(window.makeFirstResponder(page))
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 9,
                                                 windowNumber: window.windowNumber, context: nil, characters: "a",
                                                 charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 9.1,
                                               windowNumber: window.windowNumber, context: nil, characters: "a",
                                               charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        page.keyDown(with: down)
        page.keyUp(with: up)
        #expect(shim.keys.map(\.key.phase) == [.down, .up])
        #expect(shim.keys[0].key.character == 97 && shim.keys[0].key.unmodifiedCharacter == 97 && shim.keys[0].key.keyCode == 0)
        // A Command chord goes to the page before the main menu while the page view is first responder.
        let chord = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 10,
                                                  windowNumber: window.windowNumber, context: nil, characters: "b",
                                                  charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        #expect(page.performKeyEquivalent(with: chord))
        #expect(shim.keys.last?.key.keyCode == 11)
        // Quit stays the app's.
        let quit = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 11,
                                                 windowNumber: window.windowNumber, context: nil, characters: "q",
                                                 charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        #expect(!page.performKeyEquivalent(with: quit))
        #expect(shim.keys.count == 3)
    }

    @Test func editMenuActionsReachTheShim() throws {
        let (_, page) = try presentedPage()
        page.copy(nil)
        page.cut(nil)
        page.paste(nil)
        page.selectAll(nil)
        page.undo(nil)
        page.redo(nil)
        page.pasteAndMatchStyle(nil)
        #expect(shim.edits.map(\.command) == [.copy, .cut, .paste, .selectAll, .undo, .redo, .pasteAndMatchStyle])
        #expect(shim.edits.allSatisfy { $0.browser == 4 })
    }

    /// Every tab of a pane shares the page window: input goes to the tab shown now.
    @Test func inputGoesToTheShownTabsBrowser() throws {
        let (hosting, page) = try presentedPage()
        hosting.pageShown(browser: 9)
        page.copy(nil)
        #expect(shim.edits.last?.browser == 9)
    }

    // MARK: Focus makes no window key

    @Test func focusAndBlurAreTheEmbeddersAndMakeNoWindowKey() throws {
        let (_, page) = try presentedPage()
        let keyBefore = NSApp.keyWindow
        let other = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(other)
        #expect(window.makeFirstResponder(page))
        #expect(window.makeFirstResponder(nil))
        #expect(shim.focus.map(\.focused) == [true, false], "page focus follows the page view's first responder state")
        #expect(shim.focus.allSatisfy { $0.browser == 4 })
        #expect(NSApp.keyWindow === keyBefore, "a presented page's focus changed the key window")
        // No Chromium page window was ever ordered in or made a child of the cmux window.
        #expect(window.childWindows?.isEmpty ?? true)
    }

    /// The page's focus is the embedder's key state: its window resigning key blurs the page, becoming key focuses it
    /// again, as a Chrome page in a window that loses and regains key.
    @Test func theWindowsKeyStateIsThePagesFocus() throws {
        let center = NotificationCenter()
        let (_, page) = try presentedPage()
        page.notificationCenter = center
        page.observeWindowKey()
        #expect(window.makeFirstResponder(page))
        page.windowIsKey = { _ in false }
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        page.windowIsKey = { _ in true }
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(shim.focus.map(\.focused) == [true, false, true])
    }

    // MARK: Cursor, forwarded keys

    @Test func chromiumsCursorShowsOverThePageView() throws {
        let (_, page) = try presentedPage()
        #expect(page.panePointerCursor(at: .zero) == NSCursor.arrow)
        page.pageCursor = .pointingHand
        #expect(page.panePointerCursor(at: .zero) == NSCursor.pointingHand)
        page.input = nil
        #expect(page.panePointerCursor(at: .zero) == nil, "a child-window page view sets no cursor")
    }

    /// CEF rebuilds a forwarded key as a window-less event with the original's time and key code: Chromium's key hooks
    /// see the original, the one cmux's key router decided.
    @Test func aRebuiltKeyMapsBackToTheForwardedOne() throws {
        let original = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .function], timestamp: 42,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\u{F702}",
                                                     charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        let rebuilt = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 42,
                                                    windowNumber: 0, context: nil, characters: "\u{F702}",
                                                    charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        var keys = CEFForwardedKeys()
        #expect(keys.original(for: rebuilt) === rebuilt)
        keys.note(original)
        #expect(keys.original(for: rebuilt) === original)
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 43,
                                                  windowNumber: 0, context: nil, characters: "x",
                                                  charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(keys.original(for: other) === other)
    }

    @Test func theWheelsModifiersAreCEFFlags() {
        let flags = UInt64(NSEvent.ModifierFlags([.shift, .command, .option, .control]).rawValue)
        #expect(CEFPresentedCalls.cefFlags(flags, buttons: 1) == (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 7))
        #expect(CEFPresentedCalls.cefFlags(0, buttons: 2) == 1 << 6)
    }
}
