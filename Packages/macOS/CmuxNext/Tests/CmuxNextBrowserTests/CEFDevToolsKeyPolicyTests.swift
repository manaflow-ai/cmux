import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 033 of plans/cmux-next/chrome-parity/p01-process.md: the DevTools key handler is a policy. In
/// host mode cmux installs no DevTools key handler (the remote shim's policy is NULL and the host's
/// DevTools client asks no one); the key router decides Cmd-Opt-I in `sendEvent`, and the toggle it runs
/// decides from what cmux asked the host for, so a second press before the host's OPENED closes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFDevToolsKeyPolicyTests {
    private static let page: Int32 = 1
    private static let devTools: Int32 = 2
    private static let show = "command \(CEFShimLibrary.DevToolsCommand.show)"
    private static let close = "command \(CEFShimLibrary.DevToolsCommand.close)"

    // MARK: Handler

    @Test func hostModeInstallsNoDevToolsKeyHandler() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.installDevToolsKeyPolicy()

        #expect(runtime.devToolsKeyPolicy == .embedderFirst)
        #expect(KeySpy.handlers == [false], "host mode must leave the DevTools key_fn NULL")
    }

    @Test func inProcessInstallsThePreKeyHook() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.installDevToolsKeyPolicy()

        #expect(runtime.devToolsKeyPolicy == .preKeyHook)
        #expect(KeySpy.handlers == [true])
    }

    @Test func onlyThePreKeyHookAsksTheKeyRouter() throws {
        for hostMode in [false, true] {
            let (runtime, root) = try Self.runtime(hostMode: hostMode)
            defer { try? FileManager.default.removeItem(at: root) }
            let tab = Self.tab(runtime)
            let router = CountingRouter()
            tab.keyRouter = router

            let routed = runtime.routeDevToolsKey(try Self.commandOptionI(), inspected: Self.page)

            #expect(routed == !hostMode)
            #expect(router.devToolsKeys == (hostMode ? 0 : 1), "host mode asked cmux from the host's DevTools client")
        }
    }

    // MARK: Toggle

    @Test func hostModeASecondToggleBeforeOpenedCloses() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        controller.perform(.toggle)
        #expect(controller.isOpenOrRequested)
        controller.perform(.toggle)

        #expect(KeySpy.log == ["place \(Self.page)", Self.show, Self.close],
                "the second Cmd-Opt-I asked to open again instead of closing")
        #expect(!controller.isOpenOrRequested)

        // The host answers in wire order: opened, then closed. The next press opens again.
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(!tab.devTools.isOpen)
        KeySpy.log = []
        controller.perform(.toggle)
        #expect(KeySpy.log == [Self.show])
    }

    @Test func hostModeAToggleOfAnOpenDevToolsCloses() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        #expect(tab.devTools.isOpen)
        KeySpy.log = []

        controller.perform(.toggle)

        #expect(KeySpy.log == [Self.close])
    }

    @Test func hostModeAnUnplacedOpenClosedBeforeItOpenedIsNotReopened() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        controller.perform(.toggle)
        KeySpy.log = []

        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        // The closed event places again for the next open (the placement stands); no command opens.
        #expect(KeySpy.log.filter { $0.hasPrefix("command") } == [Self.close], "a DevTools the person closed came back")
        #expect(!tab.devTools.isOpen)
    }

    @Test func hostModeAnOpenTheHostNeverAnsweredDoesNotStickTheToggle() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        controller.perform(.toggle)
        KeySpy.log = []

        controller.perform(.toggle)

        #expect(KeySpy.log == [Self.show])
    }

    // MARK: Helpers

    private static func commandOptionI() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                      timestamp: 0, windowNumber: 0, context: nil, characters: "\u{02C6}",
                                      charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
    }

    /// A runtime that outlives the test (a tab's scheduled work reads it through an unowned reference).
    private static func runtime(hostMode: Bool) throws -> (CEFRuntime, URL) {
        KeySpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(KeySpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            let hostStart = CEFHostStart(supervisor: NoKeysHost())
            runtime.hostStart = hostStart
            runtime.hostReplies = try CEFHostReplyRoute(symbol: KeySpy.symbol, replies: hostStart.replies)
        }
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    private static func tab(_ runtime: CEFRuntime) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: page)
        tab.devToolsController.layout = CEFDevToolsLayout()
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        KeySpy.log = []
        return tab
    }
}

/// Counts the DevTools keys the runtime asks about; claims each one.
@MainActor private final class CountingRouter: BrowserKeyRouting {
    var devToolsKeys = 0

    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition { .passToPage }

    func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        devToolsKeys += 1
        return .handledByHost
    }
}

/// Never attaches: these tests drive the policy against the spy shim and never start Chromium.
@MainActor private final class NoKeysHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// Stand-in shim functions: `devtools_set_key_handler` records whether a handler came, the DevTools
/// placement and commands record in order; every other symbol returns 0.
private nonisolated enum KeySpy {
    nonisolated(unsafe) static var handlers: [Bool] = []
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var lastToken: UInt32 = 0

    static func reset() {
        handlers = []
        log = []
        lastToken = 0
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFHostReplyRoute.LastReplyTokenFn = { KeySpy.lastToken }
        let setKeyHandler: @convention(c) (CEFShimLibrary.KeyFn?) -> Void = { handler in
            KeySpy.handlers.append(handler != nil)
        }
        let setPlacement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = {
            browser, _, _, _, _, _ in
            KeySpy.log.append("place \(browser)")
        }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { _, command, _, _ in
            KeySpy.log.append("command \(command)")
            return 1
        }
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { _, _ in
            KeySpy.lastToken += 1
            return 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_set_key_handler": unsafeBitCast(setKeyHandler, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_set_placement": unsafeBitCast(setPlacement, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
