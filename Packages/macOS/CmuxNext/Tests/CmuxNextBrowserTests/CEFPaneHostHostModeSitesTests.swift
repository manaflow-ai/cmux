import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Task 023 of plans/cmux-next/chrome-parity/p01-process.md: the pane host's shim sites take the
/// form host mode needs, in both backends. The page's parent is the token of the pane's
/// `ChromiumHostPageView` in host mode (the in-process `CEFHostView` otherwise), the page view shows
/// the context id of the host's REPLY, the fork's layer hosting of a page window over the host view
/// runs only in process, a remote machine's proxy waits for the host's REPLY before the window is
/// asked for (fail closed, with a deadline on the main deadline queue), and a refused move or attach
/// closes its tab. REPLYs are resolved in the host start's reply table, the one the remote shim's
/// reply callback resolves.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFPaneHostHostModeSitesTests {
    // MARK: Page parent

    @Test func inProcessTheWindowsParentIsTheHostView() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)

        host.ensureCreated(tab)

        #expect(PaneSpy.windowParents == [Self.pointer(host.hostView)])
        #expect(host.hostedPageView == nil, "no page view in process: the fork's page window shows the page")
    }

    @Test func hostModeTheWindowsParentIsThePanesPageViewToken() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)

        host.ensureCreated(tab)

        let page = try #require(host.hostedPageView)
        #expect(page.wireToken != 0)
        #expect(PaneSpy.windowParents == [Self.token(page)], "a view pointer reached the remote shim")
        #expect(page.superview === host.hostView)
        #expect(host.hostView.subviews.first === page, "under the find bar, prompt bar and every other subview")
        #expect(page.inputTarget == .pageWindow, "no input route to the host yet: the host view keeps the input")
        #expect(page.hitTest(NSPoint(x: 1, y: 1)) == nil)
        #expect(page.frame == host.hostView.bounds)

        // A later window of the same pane names the same page view (one token on the wire).
        #expect(host.pageParent() == CEFParentView(token: page.wireToken))
        // Another pane's page view has a token of its own.
        let (other, otherTab) = Self.pane(runtime)
        other.ensureCreated(otherTab)
        let otherPage = try #require(other.hostedPageView)
        #expect(otherPage.wireToken != 0 && otherPage.wireToken != page.wireToken)
    }

    /// A tab's page is a child window only in process; in host mode it is the pane's page view, in
    /// the view tree (task 028), so App code that reaches page windows leaves host pages alone.
    @Test(arguments: [false, true])
    func aTabIsAChildWindowPageOnlyInProcess(hostMode: Bool) async throws {
        let (runtime, root) = try await Self.runtime(hostMode: hostMode)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime)
        host.ensureCreated(tab)

        #expect(tab.presentation == (hostMode ? .inView : .childWindow))
    }

    /// Host mode: the window's page shows in the pane's page view, so the fork's layer hosting of a
    /// page window over the host view gets no fork; in process it does (fork API 27).
    @Test(arguments: [false, true])
    func onlyAnInProcessPageWindowIsForkLayerHosted(hostMode: Bool) async throws {
        let (runtime, root) = try await Self.runtime(hostMode: hostMode)
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
        }
    }

    /// Host mode: the pane's window asks the host for its page context once, and the page view
    /// shows the id of the host's REPLY.
    @Test func hostModeThePageViewShowsTheContextOfTheHostsReply() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let (host, _) = try Self.livePane(runtime)
        let page = try #require(host.hostedPageView)

        #expect(PaneSpy.layerHosting.map(\.browser) == [Self.firstBrowser])
        #expect(PaneSpy.layerHosting.map(\.enabled) == [1])
        #expect(page.contextID == 0, "a context showed before the host answered")
        replies.resolve(PaneSpy.layerHostingTokens[0], fields: Self.int32(Int32(bitPattern: 0x8000_0042)))

        #expect(page.contextID == 0x8000_0042)
        #expect(replies.count == 0)
    }

    /// A refused context (0) shows none; a REPLY for a window the pane no longer has shows nothing.
    @Test func hostModeARefusedOrStaleContextShowsNothing() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let (host, _) = try Self.livePane(runtime)
        let page = try #require(host.hostedPageView)

        replies.resolve(PaneSpy.layerHostingTokens[0], fields: Self.int32(0))
        #expect(page.contextID == 0)

        let (closing, closingTab) = try Self.livePane(runtime, browser: Self.firstBrowser + 10)
        let closingPage = try #require(closing.hostedPageView)
        closing.removed(closingTab)
        replies.resolve(PaneSpy.layerHostingTokens[1], fields: Self.int32(77))
        #expect(closingPage.contextID == 0, "a closed pane's page view showed a context")
    }

    @Test func aClosedPanesPageViewShowsNoContext() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
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

    @Test func inProcessAStoredMachineProxyOpensTheWindow() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
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
    func inProcessAnUnstoredMachineProxyFailsTheTab(state: Int32) async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        PaneSpy.proxyState = state

        host.ensureCreated(tab)

        #expect(runtime.pendingWindows.isEmpty)
        #expect(PaneSpy.windowParents.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    @Test func aMachineProxyOnPortZeroIsNeverSent() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 0)
        PaneSpy.proxyState = 2

        host.ensureCreated(tab)

        #expect(PaneSpy.proxyPorts.isEmpty, "the shim would refuse it and keep an older proxy")
        #expect(PaneSpy.windowParents.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    @Test func hostModeTheWindowWaitsForTheMachineProxysReply() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)

        host.ensureCreated(tab)
        host.ensureCreated(tab)

        #expect(PaneSpy.proxyPorts == [9_000], "a second ask sent the proxy again")
        #expect(PaneSpy.tokens.count == 1)
        #expect(runtime.pendingWindows.isEmpty, "the window was asked for before the host stored the proxy")
        #expect(!Self.showsFailure(tab))

        replies.resolve(PaneSpy.tokens[0], fields: Self.int32(1))

        #expect(runtime.pendingWindows.count == 1)
        #expect(PaneSpy.windowParents.count == 1)
        #expect(PaneSpy.proxyPorts.count == 1, "the answered proxy was sent again")
        #expect(host.machineProxyWaits.isEmpty)
    }

    @Test func hostModeARefusedMachineProxyFailsTheTab() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        host.ensureCreated(tab)

        replies.resolve(PaneSpy.tokens[0], fields: Self.int32(-1))

        #expect(runtime.pendingWindows.isEmpty)
        #expect(Self.showsFailure(tab))
    }

    /// A host that never answers fails the tab at the reply deadline, not never.
    @Test func hostModeAMachineProxyWithNoReplyFailsAtTheDeadline() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = HostRepliesHarness.deadlines(of: runtime)
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        host.ensureCreated(tab)
        rig.advance(by: CEFRuntime.siteReplyTimeout - .milliseconds(1))
        #expect(!Self.showsFailure(tab))

        rig.advance(by: .seconds(2))

        #expect(Self.showsFailure(tab))
        #expect(runtime.pendingWindows.isEmpty)
        #expect(host.machineProxyWaits.isEmpty)
    }

    @Test func hostModeAMachineProxyFailsClosedWhenTheHostGoes() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab) = Self.pane(runtime, proxyPort: 9_000)
        host.ensureCreated(tab)

        runtime.hostGone()

        #expect(runtime.pendingWindows.isEmpty)
        #expect(Self.showsFailure(tab))
        #expect(host.machineProxyWaits.isEmpty)
    }

    // MARK: Moves and attaches

    @Test func aPopupMovesIntoItsOwnWindow() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _) = try Self.livePane(runtime)
        let popup = Self.waitingPopup(in: host, runtime)

        host.movePopupsIn()

        #expect(PaneSpy.moves.map(\.browser) == [Self.firstBrowser + 1])
        #expect(PaneSpy.moves.map(\.window) == [Self.firstBrowser])
        #expect(!popup.awaitsWindowMove)
        #expect(!popup.isClosed)
    }

    /// A move the fork refuses leaves the popup in its opener's window: it closes rather than take
    /// over the opener's pane.
    @Test func aPopupWhoseMoveTheForkRefusesCloses() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _) = try Self.livePane(runtime)
        let popup = Self.waitingPopup(in: host, runtime)
        PaneSpy.moveResult = 0

        host.movePopupsIn()

        #expect(PaneSpy.moves.map(\.browser) == [Self.firstBrowser + 1])
        #expect(popup.isClosed)
    }

    /// A fork without `cmux_tab_move_to_window` (API < 3): the popup closes rather than take over its
    /// opener's pane, and no move is sent.
    @Test func aPopupOnAForkThatCannotMoveCloses() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _) = try Self.livePane(runtime)
        let popup = Self.waitingPopup(in: host, runtime)
        PaneSpy.forkAPI = 2

        host.movePopupsIn()

        #expect(PaneSpy.moves.isEmpty)
        #expect(popup.isClosed)
    }

    @Test(arguments: [false, true])
    func aPopupWindowAttachesOverThePageParent(hostMode: Bool) async throws {
        let (runtime, root) = try await Self.runtime(hostMode: hostMode)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab, content) = try Self.popupPane(runtime)

        host.present(tab, in: content)

        let page = host.hostedPageView
        #expect((page != nil) == hostMode, "a page view only in host mode")
        #expect(PaneSpy.attaches.map(\.window) == [7])
        #expect(PaneSpy.attaches.map(\.parent) == [page.flatMap(Self.token) ?? Self.pointer(host.hostView)])
        #expect(host.isLive)
        #expect(!tab.isClosed)
    }

    /// An attach the fork refuses closes the tab, so no hidden window stays behind.
    @Test func aPopupWindowThatDoesNotAttachClosesItsTab() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab, content) = try Self.popupPane(runtime)
        PaneSpy.attachResult = 0

        host.present(tab, in: content)

        #expect(PaneSpy.attaches.map(\.window) == [7])
        #expect(!host.isLive)
        #expect(tab.isClosed)
    }

    // MARK: Keys

    /// A hosted page gets page-ownable keys first (`KeyRouter.Facts.pageReportsUnhandledKeys`) only
    /// while its page view has the keyboard and its host reports the chords the page leaves
    /// unhandled. Until the input route lands, cmux runs its actions before the page as before.
    @Test func aHostedPageHasTheKeysOnlyWhileItsHostReportsThem() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, tab, window) = try Self.presentedPopupPane(runtime)
        defer { window.close() }
        #expect(!tab.hostedPageHasKeys(in: window), "the pane's page view has no input route yet")

        let page = Self.keyedPage(in: host)
        #expect(window.makeFirstResponder(page))
        #expect(!tab.hostedPageHasKeys(in: window), "a host that reports no unhandled key")
        page.hostReportsUnhandledKeys = true
        #expect(tab.hostedPageHasKeys(in: window))
        #expect(window.makeFirstResponder(nil))
        #expect(!tab.hostedPageHasKeys(in: window), "the page view lost the keyboard")
    }

    /// KEY_UNHANDLED for a chord: with no cmux action held for it (this tab has no key router), the
    /// held key goes to the menus, once; a report from another browser takes nothing.
    @Test func anUnhandledChordGoesToTheMenusOnce() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _, window) = try Self.presentedPopupPane(runtime)
        defer { window.close() }
        let page = Self.keyedPage(in: host)
        let seen = ChromiumHostPageViewKeyTests.Redispatches()
        page.redispatchTarget = { event in
            seen.events.append(event)
            return true
        }
        let cmdK = try ChromiumHostPageViewKeyTests.key("k", keyCode: 40, modifiers: .command)
        page.keyDowns.record(cmdK, ChromiumHostInputReceipt(browser: Self.firstBrowser, seq: 7))

        runtime.handle(.keyUnhandledChord(browser: Self.firstBrowser + 1, seq: 7))
        #expect(seen.events.isEmpty, "another browser's report took the key")
        runtime.handle(.keyUnhandledChord(browser: Self.firstBrowser, seq: 7))
        runtime.handle(.keyUnhandledChord(browser: Self.firstBrowser, seq: 7))
        #expect(seen.events.count == 1 && seen.events.first === cmdK)
    }

    // MARK: Page cursor (task 045)

    /// Host mode: a CURSOR shows on the pane's page view while its tab is the shown one; a hidden
    /// tab's cursor waits, and each tab's last cursor comes back when it shows again (a renderer
    /// sends its cursor only when it changes).
    @Test func hostModeShowsTheShownTabsPageCursor() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.livePane(runtime)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.present(first, in: container)
        let page = try #require(host.hostedPageView)
        #expect(page.pageCursorName == "default", "the arrow until the page sets one")

        runtime.handle(.pageView(browser: Self.firstBrowser, .cursor(.builtIn(3))))
        #expect(page.pageCursorName == "text")

        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(second)
        runtime.register(second, browser: Self.firstBrowser + 1)
        host.present(second, in: container)
        #expect(page.pageCursorName == "default", "the first tab's cursor is not the second's")
        runtime.handle(.pageView(browser: Self.firstBrowser + 1, .cursor(.builtIn(18))))
        #expect(page.pageCursorName == "col-resize")
        runtime.handle(.pageView(browser: Self.firstBrowser, .cursor(.builtIn(2))))
        #expect(page.pageCursorName == "col-resize", "a hidden tab's cursor does not show")

        host.present(first, in: container)
        #expect(page.pageCursorName == "pointer")
        host.present(second, in: container)
        #expect(page.pageCursorName == "col-resize")
    }

    /// Task 054: the shown tab's TOOLTIP shows on the page view; a hidden tab's does not.
    @Test func hostModeShowsTheShownTabsTooltip() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.livePane(runtime)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.present(first, in: container)
        let page = try #require(host.hostedPageView)
        #expect(page.pageTooltip == nil)
        runtime.handle(.pageView(browser: Self.firstBrowser, .tooltip("Close")))
        #expect(page.pageTooltip == "Close")
        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(second)
        runtime.register(second, browser: Self.firstBrowser + 1)
        host.present(second, in: container)
        #expect(page.pageTooltip == nil, "the first tab's tooltip is not the second's")
        runtime.handle(.pageView(browser: Self.firstBrowser, .tooltip("Hidden")))
        #expect(page.pageTooltip == nil, "a hidden tab's tooltip does not show")
        runtime.handle(.pageView(browser: Self.firstBrowser + 1, .tooltip("Shown")))
        #expect(page.pageTooltip == "Shown")
        runtime.handle(.pageView(browser: Self.firstBrowser + 1, .tooltip("")))
        #expect(page.pageTooltip == nil)
    }

    // MARK: Fixtures

    /// The first browser's id: a window's AFTER_CREATED names it.
    private static let firstBrowser: Int32 = 1

    private static func pointer(_ view: NSView) -> UnsafeMutableRawPointer? {
        Unmanaged.passUnretained(view).toOpaque()
    }

    /// What the shim's parent view argument carries for a host-mode page view: its token.
    private static func token(_ page: ChromiumHostPageView) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(page.wireToken))
    }

    private static func showsFailure(_ tab: CEFTab) -> Bool {
        if case .failed = tab.state.phase { return true }
        return false
    }

    /// A runtime that outlives the test (a pane's scheduled work reads it through an unowned
    /// reference); in host mode attached to the spy, with a host that maps minted ids, whose REPLYs
    /// resolve in the host start's table.
    private static func runtime(hostMode: Bool) async throws -> (CEFRuntime, URL) {
        PaneSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-pane-sites-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PaneSpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            let hostStart = try await HostRepliesHarness.attachedHost(over: { PaneSpy.symbol($0) })
            hostStart.mapsClientIDs = true
            runtime.hostStart = hostStart
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

    /// A pane whose window is live, its first tab the window's browser, `browser`.
    private static func livePane(_ runtime: CEFRuntime, browser: Int32 = firstBrowser) throws -> (CEFPaneHost, CEFTab) {
        let (host, tab) = pane(runtime)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        #expect(host.isLive)
        #expect(tab.browserID == browser)
        return (host, tab)
    }

    /// A popup still in its opener's window, waiting to move into `host`'s.
    private static func waitingPopup(in host: CEFPaneHost, _ runtime: CEFRuntime) -> CEFTab {
        let popup = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        popup.awaitsWindowMove = true
        host.add(popup)
        runtime.register(popup, browser: firstBrowser + 1)
        return popup
    }

    /// A popup host whose popup window waits to attach, and the content view its tab shows in.
    private static func popupPane(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
        let (host, tab) = pane(runtime)
        host.popupWindow = 7
        runtime.register(tab, browser: firstBrowser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        return (host, tab, try #require(window.contentView))
    }

    /// ``popupPane(_:)`` with its tab shown in a window of the test's own (close it after).
    private static func presentedPopupPane(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSWindow) {
        let (host, tab, _) = try popupPane(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        host.present(tab, in: try #require(window.contentView))
        return (host, tab, window)
    }

    /// A page view that takes the input (the route tasks 041 and 042 give the pane) in place of the
    /// pane's.
    private static func keyedPage(in host: CEFPaneHost) -> ChromiumHostPageView {
        let page = ChromiumHostPageView(frame: host.hostView.bounds, inputTarget: .view)
        host.hostView.addSubview(page)
        host.hostedPageView = page
        return page
    }

    /// An EncodeFields body with one int32 field (chromium_host_tlv.h: type 1, tag 0, length 4).
    private static func int32(_ value: Int32) -> [UInt8] {
        [1, 0, 4, 0] + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

/// Stand-in shim functions. `create_window` and `popup_window_attach` record their parent view,
/// `set_context_proxy` its port, `tab_move_to_window` its browsers; `context_proxy_state` and
/// `browser_set_layer_hosting` make the next reply token current, as the remote shim does for an
/// async op (in process nobody reads it), and answer `proxyState` and 0; `fork_api_version` reports
/// `forkAPI`; every other function does nothing and returns 0.
private nonisolated enum PaneSpy {
    nonisolated(unsafe) static var windowParents: [UnsafeMutableRawPointer?] = []
    nonisolated(unsafe) static var attaches: [(window: Int32, parent: UnsafeMutableRawPointer?)] = []
    nonisolated(unsafe) static var attachResult: Int32 = 1
    nonisolated(unsafe) static var proxyPorts: [Int32] = []
    nonisolated(unsafe) static var proxyState: Int32 = 1
    nonisolated(unsafe) static var moves: [(browser: Int32, window: Int32)] = []
    nonisolated(unsafe) static var moveResult: Int32 = 1
    nonisolated(unsafe) static var forkAPI: Int32 = 27
    nonisolated(unsafe) static var layerHosting: [(browser: Int32, enabled: Int32)] = []
    nonisolated(unsafe) static var layerHostingTokens: [UInt32] = []
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
        layerHosting = []
        layerHostingTokens = []
        lastToken = 0
        tokens = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { PaneSpy.lastToken }
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
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, enabled in
            PaneSpy.layerHosting.append((browser, enabled))
            PaneSpy.lastToken = 300 + UInt32(PaneSpy.layerHostingTokens.count)
            PaneSpy.layerHostingTokens.append(PaneSpy.lastToken)
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
