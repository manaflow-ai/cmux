import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task 229: the runtime's side of host mode's locks. The lock fn goes into the shim only from fork
/// API 31; each request is answered at once, refused for a page that is not shown with the keyboard;
/// exits, locked moves and the fullscreen exit reach the shim's calls for the page's browser.
@MainActor
@Suite struct CEFHostLocksTests {
    static func runtime() throws -> (CEFRuntime, URL) {
        LockSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-locks-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(LockSpy.symbol), storage: CEFProfileStorage(root: root))
        // A pane's scheduled work reads the runtime through an unowned reference.
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    @Test func theLockFnNeedsForkAPI31() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try #require(runtime.shim)
        let locks = CEFHostLocks(runtime: runtime, appEvents: nil)
        locks.install(shim, forkAPIVersion: 30, context: nil)
        #expect(LockSpy.calls.isEmpty && !locks.isInstalled)
        locks.install(shim, forkAPIVersion: 31, context: nil)
        #expect(LockSpy.calls == ["handler set"] && locks.isInstalled)
    }

    @Test func aRequestOfAPageWithoutTheKeyboardIsRefusedAtOnce() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.popupWindow = 3
        runtime.register(tab, browser: 7)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let page = ChromiumHostPageView(frame: host.hostView.bounds, inputTarget: .view)
        host.hostView.addSubview(page)
        host.hostedPageView = page
        let locks = CEFHostLocks(runtime: runtime, appEvents: nil)
        locks.serve(page)
        #expect(page.exclusiveAccess.wire === locks)

        locks.received(ChromiumHostLockEvent.pointerLockRequested.rawValue, browser: 7, detail: 0)
        locks.received(ChromiumHostLockEvent.keyboardLockRequested.rawValue, browser: 7, detail: 1)
        locks.received(ChromiumHostLockEvent.pointerLockRequested.rawValue, browser: 9, detail: 0)  // no tab of cmux's
        locks.received(42, browser: 7, detail: 0)  // an event this side does not know
        #expect(LockSpy.calls == ["pointer answer 7 0", "keyboard answer 7 0", "pointer answer 9 0"])
        #expect(page.exclusiveAccess.pointerLock == nil && page.exclusiveAccess.keyboardLock == nil)

        LockSpy.calls = []
        locks.exitPointerLock(7, byUser: true)
        locks.exitKeyboardLock(7)
        locks.sendLockedMove(7, dx: 1.5, dy: -2, modifiers: 16)
        #expect(LockSpy.calls == ["exit pointer 7 1", "exit keyboard 7", "move 7 1.5,-2.0 16"])
    }

    /// HTML fullscreen in host mode with cmux's locks: the page's tab asks its host to zoom its pane on
    /// enter and to give the zoom back on exit, on the host's end and when the tab goes away, and the page
    /// view holds the fullscreen for Escape. A served page view gets the held-Escape deadline.
    @Test func fullscreenAsksThePaneZoomAndEveryEndGivesItBack() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        let intents = IntentRecorder()
        tab.delegate = intents
        host.add(tab)
        host.popupWindow = 3
        runtime.register(tab, browser: 7)
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let page = ChromiumHostPageView(frame: host.hostView.bounds, inputTarget: .view)
        host.hostView.addSubview(page)
        host.hostedPageView = page
        // Host mode with cmux's locks from here on (the supervisor never attaches).
        runtime.adoptHost(SilentLockHost(), handlesLocks: true)
        runtime.hostStart?.locks?.serve(page)
        #expect(page.exclusiveAccess.holdTimer != nil)

        tab.handle(.fullscreen(browser: 7, entering: true))
        #expect(intents.fullscreen == [true] && tab.state.isContentFullscreen)
        #expect(page.exclusiveAccess.fullscreen == 7)
        tab.handle(.fullscreen(browser: 7, entering: false))
        #expect(intents.fullscreen == [true, false] && !tab.state.isContentFullscreen)

        tab.handle(.fullscreen(browser: 7, entering: true))
        tab.hostEnded(BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef))
        #expect(intents.fullscreen == [true, false, true, false], "the host's end gives the zoom back")
        #expect(!tab.state.isContentFullscreen)
    }

    /// In process (no locks), a page's fullscreen stays in its pane as before: no zoom is asked.
    @Test func withoutCmuxLocksFullscreenAsksNoZoom() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        let intents = IntentRecorder()
        tab.delegate = intents
        tab.handle(.fullscreen(browser: 7, entering: true))
        #expect(tab.state.isContentFullscreen)
        #expect(intents.fullscreen.isEmpty)
    }

    /// CMUX_SHIM_LOCK (61) is the remote shim's for cmux's lock fn: as an event it is nothing cmux handles.
    @Test func aLockPushIsNoEvent() {
        #expect(CEFShimEvent(kind: 61, browser: 7, request: 0, a: 1, b: 0, s1: "", s2: "") == .unknown(kind: 61))
        #expect(ChromiumHostEventKind(rawValue: 61) == .lock)
    }
}

/// Stand-in shim functions: the lock calls record themselves; every other function does nothing and returns 0.
private nonisolated enum LockSpy {
    nonisolated(unsafe) static var calls: [String] = []

    static func reset() {
        calls = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let setHandler: @convention(c) (CEFShimLockOps.Handler?, UnsafeMutableRawPointer?) -> Int32 = { handler, _ in
            LockSpy.calls.append(handler == nil ? "handler removed" : "handler set")
            return 1
        }
        let pointerAnswer: @convention(c) (Int32, Int32) -> Int32 = { browser, allowed in
            LockSpy.calls.append("pointer answer \(browser) \(allowed)")
            return 1
        }
        let keyboardAnswer: @convention(c) (Int32, Int32) -> Int32 = { browser, allowed in
            LockSpy.calls.append("keyboard answer \(browser) \(allowed)")
            return 1
        }
        let exitPointer: @convention(c) (Int32, Int32) -> Int32 = { browser, byUser in
            LockSpy.calls.append("exit pointer \(browser) \(byUser)")
            return 1
        }
        let exitKeyboard: @convention(c) (Int32) -> Int32 = { browser in
            LockSpy.calls.append("exit keyboard \(browser)")
            return 1
        }
        let move: @convention(c) (Int32, Double, Double, Int32) -> Int32 = { browser, dx, dy, modifiers in
            LockSpy.calls.append("move \(browser) \(dx),\(dy) \(modifiers)")
            return 1
        }
        let popupWindowAttach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_set_lock_handler": unsafeBitCast(setHandler, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_pointer_lock_answer": unsafeBitCast(pointerAnswer, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_keyboard_lock_answer": unsafeBitCast(keyboardAnswer, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_exit_pointer_lock": unsafeBitCast(exitPointer, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_exit_keyboard_lock": unsafeBitCast(exitKeyboard, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_send_locked_mouse_move": unsafeBitCast(move, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_attach": unsafeBitCast(popupWindowAttach, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}

/// The fullscreen intents a tab sends its host, in order.
@MainActor private final class IntentRecorder: BrowserTabDelegate {
    var fullscreen: [Bool] = []

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        if case .contentFullscreen(let entering) = intent { fullscreen.append(entering) }
    }
}

/// A host supervisor that never attaches: the runtime is in host mode and never starts.
@MainActor private final class SilentLockHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}
