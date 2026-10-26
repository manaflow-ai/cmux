import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 023 of plans/cmux-next/chrome-parity/p01-process.md: the pane host's shim sites take the
/// form host mode needs, in both backends. The page's parent view is the pane's
/// `ChromiumHostPageView` in host mode (the in-process `CEFHostView` otherwise), the fork's layer
/// hosting of a page window runs only in process, a remote machine's proxy waits for the host's
/// REPLY before the window is asked for (fail closed), and no caller reads the result of a
/// one-way move or attach.
@MainActor @Suite(.serialized) struct CEFPaneHostHostModeSitesTests {
    // MARK: Page parent

    @Test func inProcessTheWindowsParentIsTheHostView() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)

        host.ensureCreated(tab)

        #expect(PaneSpy.windowParents == [Self.pointer(host.hostView)])
        #expect(host.hostedPageView == nil, "no page view in process: the fork's page window shows the page")
    }

    @Test func hostModeTheWindowsParentIsThePanesPageView() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)

        host.ensureCreated(tab)

        let page = try #require(host.hostedPageView)
        #expect(PaneSpy.windowParents == [Self.pointer(page)])
        #expect(page.superview === host.hostView)
        #expect(host.hostView.subviews.first === page, "under the find bar, prompt bar and every other subview")
        #expect(page.inputTarget == .view, "the page view is the page's input target")
        #expect(page.frame == host.hostView.bounds)

        // A later window of the same pane names the same page view (one token on the wire).
        #expect(host.pageParent() == Self.pointer(page))
    }

    /// Host mode: the window's page shows in the pane's page view, so the fork's layer hosting of a
    /// page window over the host view gets no fork; in process it does (fork API 27).
    @Test(arguments: [false, true])
    func onlyAnInProcessPageWindowIsForkLayerHosted(hostMode: Bool) throws {
        let (runtime, root) = try Self.runtime(hostMode: hostMode)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)

        runtime.handle(.afterCreated(browser: Self.firstBrowser, request: request, window: 1))
        host.showBrowser(of: tab, activate: false)

        #expect(host.isLive)
        #expect(host.hostView.layerHosting.isForkBacked == !hostMode)
        if hostMode {
            #expect(host.hostView.layerHosting.forkCalls == 0)
            #expect(PaneSpy.layerHostingCalls == 0)
        }
    }

    @Test func aClosedPanesPageViewShowsNoContext() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)
        host.ensureCreated(tab)
        let page = try #require(host.hostedPageView)
        let shown = page.show(contextID: 42)

        host.removed(tab)

        #expect(shown, "a CALayerHost shows any context id")
        #expect(page.contextID == 0)
    }

    // MARK: Remote machine proxy

    @Test func inProcessAStoredMachineProxyOpensTheWindow() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        PaneSpy.proxyState = 1

        host.ensureCreated(tab)

        #expect(PaneSpy.proxyPorts == [9_000])
        #expect(runtime.pendingWindows.count == 1)
        #expect(PaneSpy.windowParents.count == 1)
    }

    /// State 0 (nothing stored) and -1 (Chromium refused the preference): no window, fail closed.
    @Test(arguments: [Int32(0), Int32(-1)])
    func inProcessAnUnstoredMachineProxyFailsTheTab(state: Int32) throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        PaneSpy.proxyState = state

        host.ensureCreated(tab)

        #expect(runtime.pendingWindows.isEmpty)
        #expect(PaneSpy.windowParents.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    @Test func aMachineProxyOnPortZeroIsNeverSent() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 0)
        PaneSpy.proxyState = 2

        host.ensureCreated(tab)

        #expect(PaneSpy.proxyPorts.isEmpty, "the shim would refuse it and keep an older proxy")
        #expect(PaneSpy.windowParents.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    @Test func hostModeTheWindowWaitsForTheMachineProxysReply() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try #require(runtime.hostReplies)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)

        host.ensureCreated(tab)
        host.ensureCreated(tab)

        #expect(PaneSpy.proxyPorts == [9_000], "a second ask sent the proxy again")
        #expect(PaneSpy.tokens.count == 1)
        #expect(runtime.pendingWindows.isEmpty, "the window was asked for before the host stored the proxy")
        #expect(!Self.showsFailure(tab))

        route.deliver(PaneSpy.tokens[0], fields: Self.int32(1))

        #expect(runtime.pendingWindows.count == 1)
        #expect(PaneSpy.windowParents.count == 1)
        #expect(PaneSpy.proxyPorts.count == 1, "the answered proxy was sent again")
        #expect(host.machineProxyWaits.isEmpty)
    }

    @Test func hostModeARefusedMachineProxyFailsTheTab() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try #require(runtime.hostReplies)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        host.ensureCreated(tab)

        route.deliver(PaneSpy.tokens[0], fields: Self.int32(-1))

        #expect(runtime.pendingWindows.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    @Test func hostModeAMachineProxyFailsClosedWhenTheHostGoes() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try #require(runtime.hostReplies)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        host.ensureCreated(tab)

        route.hostGone()

        #expect(runtime.pendingWindows.isEmpty)
        #expect(Self.showsFailure(tab))
        #expect(host.machineProxyWaits.isEmpty)
    }

    // MARK: One-way moves and attaches

    /// The move's result is not read: in host mode it only says the op was sent.
    @Test func aPopupMovesInWithoutReadingTheMoveResult() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _) = try Self.livePane(runtime)
        let popup = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        popup.awaitsWindowMove = true
        host.add(popup)
        runtime.register(popup, browser: Self.firstBrowser + 1)
        PaneSpy.moveResult = 0

        host.movePopupsIn()

        #expect(PaneSpy.moves.map(\.browser) == [Self.firstBrowser + 1])
        #expect(PaneSpy.moves.map(\.window) == [Self.firstBrowser])
        #expect(!popup.awaitsWindowMove)
        #expect(!popup.isClosed)
    }

    /// A fork without `cmux_tab_move_to_window` (API < 3): the popup closes rather than take over its
    /// opener's pane, and no move is sent.
    @Test func aPopupOnAForkThatCannotMoveCloses() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _) = try Self.livePane(runtime)
        let popup = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        popup.awaitsWindowMove = true
        host.add(popup)
        runtime.register(popup, browser: Self.firstBrowser + 1)
        PaneSpy.forkAPI = 2

        host.movePopupsIn()

        #expect(PaneSpy.moves.isEmpty)
        #expect(popup.isClosed)
    }

    @Test(arguments: [false, true])
    func aPopupWindowAttachesOverThePageParentWithoutReadingTheResult(hostMode: Bool) throws {
        let (runtime, root) = try Self.runtime(hostMode: hostMode)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)
        host.popupWindow = 7
        runtime.register(tab, browser: Self.firstBrowser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        let content = try #require(window.contentView)
        PaneSpy.attachResult = 0

        host.present(tab, in: content)

        let page = host.hostedPageView
        #expect((page != nil) == hostMode, "a page view only in host mode")
        let parent: NSView = page ?? host.hostView
        #expect(PaneSpy.attaches.map(\.window) == [7])
        #expect(PaneSpy.attaches.map(\.parent) == [Self.pointer(parent)])
        #expect(host.isLive, "the attach is one-way: its window is the popup host's")
        #expect(!tab.isClosed)
    }

    // MARK: Fixtures

    /// The first browser's id: a window's AFTER_CREATED names it.
    private static let firstBrowser: Int32 = 1

    private static func pointer(_ view: NSView) -> UnsafeMutableRawPointer? {
        Unmanaged.passUnretained(view).toOpaque()
    }

    private static func showsFailure(_ tab: CEFTab) -> Bool {
        if case .failed = tab.state.phase { return true }
        return false
    }

    /// A runtime that outlives the test (a pane's scheduled work reads it through an unowned
    /// reference); in host mode with a host that maps minted ids and a reply route.
    private static func runtime(hostMode: Bool) throws -> (CEFRuntime, URL) {
        PaneSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-pane-sites-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PaneSpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            runtime.hostStart = CEFHostStart(supervisor: NoHost())
            runtime.hostStart?.mapsClientIDs = true
            runtime.hostReplies = try CEFHostReplyRoute(symbol: PaneSpy.symbol)
        }
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A pane with one tab and no window yet; the tab's store is a remote machine's when `proxyPort`
    /// is given.
    private static func pane(_ runtime: CEFRuntime, proxyPort: UInt16? = nil) -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        if let proxyPort {
            tab.machineStore = BrowserMachineStore(machineKey: "machine-a", machineName: "Machine A", proxyPort: proxyPort)
        }
        host.add(tab)
        return (host, tab)
    }

    /// A pane whose window is live, its first tab the window's browser.
    private static func livePane(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab) {
        let (host, tab) = pane(runtime)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: firstBrowser, request: request, window: 1))
        #expect(host.isLive)
        #expect(tab.browserID == firstBrowser)
        return (host, tab)
    }

    /// An EncodeFields body with one int32 field (chromium_host_tlv.h: type 1, tag 0, length 4).
    private static func int32(_ value: Int32) -> [UInt8] {
        [1, 0, 4, 0] + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

/// Never attaches: these tests drive panes against the spy shim and never start Chromium.
@MainActor private final class NoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// Stand-in shim functions. `create_window` and `popup_window_attach` record their parent view,
/// `set_context_proxy` its port, `tab_move_to_window` its browsers; `context_proxy_state` makes the
/// next reply token current, as the remote shim does for an async op (in process nobody reads it),
/// and answers `proxyState`; `fork_api_version` reports `forkAPI`; `browser_set_layer_hosting`
/// counts its calls; every other function does nothing and returns 0.
private nonisolated enum PaneSpy {
    nonisolated(unsafe) static var windowParents: [UnsafeMutableRawPointer?] = []
    nonisolated(unsafe) static var attaches: [(window: Int32, parent: UnsafeMutableRawPointer?)] = []
    nonisolated(unsafe) static var attachResult: Int32 = 1
    nonisolated(unsafe) static var proxyPorts: [Int32] = []
    nonisolated(unsafe) static var proxyState: Int32 = 1
    nonisolated(unsafe) static var moves: [(browser: Int32, window: Int32)] = []
    nonisolated(unsafe) static var moveResult: Int32 = 1
    nonisolated(unsafe) static var forkAPI: Int32 = 27
    nonisolated(unsafe) static var layerHostingCalls = 0
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    nonisolated(unsafe) static var tokens: [UInt32] = []

    static func reset() {
        windowParents = []
        attaches = []
        attachResult = 1
        proxyPorts = []
        proxyState = 1
        moves = []
        moveResult = 1
        forkAPI = 27
        layerHostingCalls = 0
        lastToken = 0
        tokens = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFHostReplyRoute.LastReplyTokenFn = { PaneSpy.lastToken }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, parent, _, _, _, _ in
            PaneSpy.windowParents.append(parent)
            return 1
        }
        let popupWindowAttach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { window, parent, _, _ in
            PaneSpy.attaches.append((window, parent))
            return PaneSpy.attachResult
        }
        let setContextProxy: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32 = { _, port in
            PaneSpy.proxyPorts.append(port)
            return 1
        }
        let contextProxyState: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { _ in
            PaneSpy.lastToken = 200 + UInt32(PaneSpy.tokens.count)
            PaneSpy.tokens.append(PaneSpy.lastToken)
            return PaneSpy.proxyState
        }
        let tabMoveToWindow: @convention(c) (Int32, Int32, Int32) -> Int32 = { browser, window, _ in
            PaneSpy.moves.append((browser, window))
            return PaneSpy.moveResult
        }
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { _, _ in
            PaneSpy.layerHostingCalls += 1
            return 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { PaneSpy.forkAPI }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_attach": unsafeBitCast(popupWindowAttach, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_context_proxy": unsafeBitCast(setContextProxy, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_context_proxy_state": unsafeBitCast(contextProxyState, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_move_to_window": unsafeBitCast(tabMoveToWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
