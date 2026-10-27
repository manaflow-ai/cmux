import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 024 of plans/cmux-next/chrome-parity/p01-process.md: in host mode a tab's DevTools is a
/// hosted context. Its placement names the token of the tab's DevTools `ChromiumHostPageView`, goes
/// before the first command or page menu that may open DevTools (the host does not wait for
/// DEVTOOLS_WILL_OPEN) and stands across DevTools closes, so Chromium's own Inspect lands placed; the
/// page view shows the context id of the host's REPLY, docked in the pane or in the DevTools panel; a
/// DevTools nothing placed closes and opens once more placed. In process the placement stays inside
/// DEVTOOLS_WILL_OPEN with the docked host view's pointer.
///
/// Task 033: in host mode cmux installs no DevTools key handler (the key router decides Cmd-Opt-I in
/// `sendEvent`, ``DevToolsKeyHostModeTests`` in CmuxNextAppTests), and the toggle decides from the
/// opens and closes in flight to the host, so a press before the host answered the one before acts
/// on what that press asked for.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFDevToolsHostedPlacementTests {
    private static let page: Int32 = 1
    private static let devTools: Int32 = 2
    private static let show = "command \(CEFShimLibrary.DevToolsCommand.show)"
    private static let close = "command \(CEFShimLibrary.DevToolsCommand.close)"

    // MARK: Placement

    @Test func hostModePlacesTheHostedPageViewBeforeTheOpenCommand() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        controller.perform(.show)

        let hosted = try #require(controller.hostedPage)
        #expect(hosted.wireToken != 0)
        #expect(DevToolsSpy.log == ["place \(Self.page)", "command \(CEFShimLibrary.DevToolsCommand.show)"],
                "the placement must reach the host before the command that opens DevTools")
        #expect(DevToolsSpy.placements.map(\.parent) == [Self.token(hosted)], "a view pointer reached the remote shim")
        #expect(DevToolsSpy.placements.allSatisfy { $0.width >= 1 && $0.height >= 1 })
        #expect(hosted.inputTarget == .pageWindow, "no input route to the host yet")

        // DEVTOOLS_WILL_OPEN comes after the host made the DevTools: it only keeps room.
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        #expect(DevToolsSpy.placements.count == 1)
        let views = try #require(controller.views)
        #expect(hosted.superview === views.host)
        #expect(views.host.subviews.first === hosted, "under every other subview")
        #expect(controller.reservesRoom)

        // While open, another open command (focus) places nothing again.
        controller.perform(.console)
        #expect(DevToolsSpy.placements.count == 1)
    }

    @Test func eachOpeningCommandPlacesFirst() async throws {
        for command in [BrowserDevToolsCommand.show, .console, .inspectElement, .toggle] {
            let (runtime, root) = try await Self.runtime(hostMode: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tab = Self.tab(runtime)
            tab.devToolsController.perform(command)
            #expect(DevToolsSpy.log.first == "place \(Self.page)", "\(command) asked for DevTools unplaced")
        }
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        tab.devToolsController.perform(.close)
        #expect(DevToolsSpy.placements.isEmpty, "closing needs no placement")
    }

    @Test func inProcessThePlacementStaysInWillOpenWithTheHostViewPointer() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(tab.container)
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        controller.pageMenuWillShow()
        controller.perform(.show)
        #expect(DevToolsSpy.placements.isEmpty, "in process the placement waits for DEVTOOLS_WILL_OPEN")

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        let views = try #require(controller.views)
        #expect(DevToolsSpy.placements.map(\.parent) == [Unmanaged.passUnretained(views.host).toOpaque()])
        #expect(controller.hostedPage == nil, "no hosted page view in process")
    }

    // MARK: Context

    @Test func hostModeADockedDevToolsShowsTheContextOfTheHostsReply() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.show)
        runtime.handle(.devToolsWillOpen(browser: Self.page))

        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))

        let hosted = try #require(controller.hostedPage)
        #expect(tab.devTools.isOpen)
        #expect(DevToolsSpy.layerHosting == [Self.devTools], "the host is asked for the DevTools page window's context")
        #expect(controller.views?.host.layerHosting.isForkBacked == false, "the fork's layer hosting is in process only")
        #expect(hosted.contextID == 0, "a context showed before the host answered")
        replies.resolve(DevToolsSpy.layerHostingTokens[0], fields: Self.int32(Int32(bitPattern: 0x8000_0024)))
        #expect(hosted.contextID == 0x8000_0024)
    }

    @Test func hostModeAReplyAfterTheDevToolsClosedShowsNothing() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = try #require(runtime.hostStart?.replies)
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        Self.open(runtime, controller)
        let hosted = try #require(controller.hostedPage)

        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        replies.resolve(DevToolsSpy.layerHostingTokens[0], fields: Self.int32(77))

        #expect(hosted.contextID == 0)
        #expect(!tab.devTools.isOpen)
        #expect(controller.hostedPlacement == Self.page, "the placement stands after its DevTools closed")
    }

    /// The placement stands across DevTools closes: a close only sends it again (a new size), with the
    /// same page view token (one host view per tab, never one per open), and the next open needs none.
    @Test func hostModeThePlacementStandsAcrossDevToolsCloses() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        Self.open(runtime, controller)
        let hosted = try #require(controller.hostedPage)
        hosted.show(contextID: 5)
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(hosted.contextID == 0, "a closed DevTools' context stayed shown")

        #expect(DevToolsSpy.placements.map(\.parent) == [Self.token(hosted), Self.token(hosted)])
        DevToolsSpy.log = []

        Self.open(runtime, controller)

        #expect(DevToolsSpy.log == ["command \(CEFShimLibrary.DevToolsCommand.show)"], "the next open placed again")
        #expect(controller.hostedPage === hosted)
        #expect(hosted.superview === controller.views?.host)
        #expect(tab.devTools.isOpen)
    }

    @Test func hostModeAnUndockedDevToolsShowsInTheDevToolsPanel() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.layout.dock = .window

        Self.open(runtime, controller)

        let hosted = try #require(controller.hostedPage)
        let panel = try #require(controller.window)
        #expect(tab.devTools.isOpen && tab.devTools.dock == .window)
        #expect(hosted.window === panel, "the hosted page view moved into the DevTools panel with its host view")
        #expect(DevToolsSpy.layerHosting == [Self.devTools])
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(controller.window == nil)
    }

    // MARK: Chromium's own opens

    /// Chromium runs the page menu's Inspect in the host: the menu places first, so that DevTools
    /// opens docked in the hosted page view at once, with no close and no second open.
    @Test func hostModeThePageMenuPlacesBeforeChromiumsInspect() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        controller.pageMenuWillShow()
        let hosted = try #require(controller.hostedPage)
        #expect(DevToolsSpy.placements.map(\.parent) == [Self.token(hosted)], "the page menu showed unplaced")
        controller.pageMenuWillShow()
        #expect(DevToolsSpy.placements.count == 1, "a standing placement goes once per browser")

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        #expect(controller.reservesRoom)
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))

        #expect(tab.devTools.isOpen)
        #expect(DevToolsSpy.log == ["place \(Self.page)"], "Chromium's Inspect was closed or opened again")
        #expect(DevToolsSpy.layerHosting == [Self.devTools])
    }

    /// An open Chromium started before anything placed lands in a top-level window of the host: it
    /// closes and a show runs once, placed. A reopen that is still unplaced was made after the
    /// placement (the host's fault) and stays closed, so this cannot loop.
    @Test func hostModeAnUnplacedOpenClosesAndShowsOncePlaced() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let close = "command \(CEFShimLibrary.DevToolsCommand.close)"
        let show = "command \(CEFShimLibrary.DevToolsCommand.show)"

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        #expect(!controller.reservesRoom, "an unplaced DevTools is not in the pane")
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        #expect(!tab.devTools.isOpen)
        #expect(DevToolsSpy.log == [close])
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(DevToolsSpy.log == [close, "place \(Self.page)", show])

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        #expect(DevToolsSpy.log == [close, "place \(Self.page)", show, close, "place \(Self.page)"],
                "an unplaced reopen opened again")
        #expect(!tab.devTools.isOpen)
    }

    /// The placed/unplaced decision comes from the event, not from cmux's state: a command cmux sends
    /// while an unplaced open is under way only focuses that DevTools, so when it opens unplaced
    /// (after cmux placed) it closes and the command runs again, placed, keeping its target.
    @Test func hostModeACommandDuringAnUnplacedOpenRunsAgainPlaced() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let console = "command \(CEFShimLibrary.DevToolsCommand.console)"
        let close = "command \(CEFShimLibrary.DevToolsCommand.close)"

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        controller.perform(.console)
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        #expect(DevToolsSpy.log == ["place \(Self.page)", console, close, "place \(Self.page)", console],
                "the console command was lost with the unplaced DevTools")
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        #expect(tab.devTools.isOpen)
    }

    // MARK: Key policy (task 033)

    @Test func hostModeInstallsNoDevToolsKeyHandler() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.installDevToolsKeyPolicy()

        #expect(runtime.devToolsKeyPolicy == .embedderFirst)
        #expect(DevToolsSpy.keyHandlers == [false], "host mode must leave the DevTools key_fn NULL")
    }

    @Test func inProcessInstallsThePreKeyHook() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.installDevToolsKeyPolicy()

        #expect(runtime.devToolsKeyPolicy == .preKeyHook)
        #expect(DevToolsSpy.keyHandlers == [true])
    }

    // MARK: Toggle (task 033)

    @Test func hostModeASecondToggleBeforeOpenedCloses() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        controller.perform(.toggle)
        #expect(controller.isOpenOrRequested)
        controller.perform(.toggle)

        #expect(DevToolsSpy.log == ["place \(Self.page)", Self.show, Self.close],
                "the second Cmd-Opt-I asked to open again instead of closing")
        #expect(!controller.isOpenOrRequested)

        // The host answers in wire order: opened, then closed. The next press opens again.
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(!tab.devTools.isOpen)
        DevToolsSpy.log = []
        controller.perform(.toggle)
        #expect(DevToolsSpy.log == [Self.show])
    }

    /// A DevTools cmux closed before the host's OPENED never shows: the close on the wire closes it.
    /// It keeps no room in the pane, and focus never moves into it (the person may be in another pane).
    @Test func hostModeAnOpenClosedBeforeItOpenedNeverShows() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let observer = DevToolsObserverSpy()
        tab.devToolsObserver = observer
        let controller = tab.devToolsController
        controller.perform(.toggle)
        controller.perform(.toggle)

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        #expect(!controller.reservesRoom, "the pane made room for a DevTools cmux already closed")
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))

        #expect(!tab.devTools.isOpen)
        #expect(!controller.reservesRoom)
        #expect(!observer.changes.contains { $0.focused }, "focus moved into a DevTools cmux already closed")
        #expect(DevToolsSpy.layerHosting.isEmpty, "the closed DevTools was shown")
        #expect(DevToolsSpy.log.filter { $0 == Self.close }.count == 1, "a second close went for one DevTools")

        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(!tab.devTools.isOpen)
        #expect(!observer.changes.contains { $0.isOpen })
    }

    @Test func hostModeAToggleOfAnOpenDevToolsCloses() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        #expect(tab.devTools.isOpen)
        DevToolsSpy.log = []

        controller.perform(.toggle)

        #expect(DevToolsSpy.log == [Self.close])
    }

    /// Four presses inside one host round trip (key repeat): show, close, show, then the host makes
    /// D1, closes it and makes D2. Each answer takes the change it answers, so the fourth press closes
    /// D2 and DevTools ends closed.
    @Test func hostModeTogglesInFlightAreAnsweredInWireOrder() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let second: Int32 = 3
        controller.perform(.toggle)
        controller.perform(.toggle)
        controller.perform(.toggle)
        #expect(DevToolsSpy.log == ["place \(Self.page)", Self.show, Self.close, Self.show])

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        DevToolsSpy.log = []

        controller.perform(.toggle)
        #expect(DevToolsSpy.log == [Self.close], "the fourth press opened again")

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: second, docked: true))
        #expect(!tab.devTools.isOpen, "a DevTools whose close is on the wire showed")
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: second))
        #expect(!tab.devTools.isOpen)
        #expect(!controller.isOpenOrRequested)
    }

    @Test func hostModeAnUnplacedOpenClosedBeforeItOpenedIsNotReopened() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        controller.perform(.toggle)
        DevToolsSpy.log = []

        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        // The close on the wire closes it; the closed event places again for the next open.
        #expect(!DevToolsSpy.log.contains { $0.hasPrefix("command") }, "a DevTools the person closed was closed again or came back")
        #expect(!tab.devTools.isOpen)
    }

    @Test func hostModeAnOpenTheHostNeverAnsweredDoesNotStickTheToggle() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.toggle)
        controller.perform(.toggle)
        DevToolsSpy.log = []

        controller.perform(.toggle)

        #expect(DevToolsSpy.log == [Self.show])
    }

    /// A host that died with an open in flight never answers it: the tab's next browser (the restarted
    /// host's) starts with nothing in flight, so Cmd-Opt-I opens.
    @Test func hostModeANewBrowserStartsWithNothingInFlight() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let restarted: Int32 = 5
        controller.perform(.toggle)
        #expect(controller.isOpenOrRequested)

        runtime.register(tab, browser: restarted)
        DevToolsSpy.log = []
        #expect(!controller.isOpenOrRequested, "the dead host's open stayed in flight")
        controller.perform(.toggle)

        #expect(DevToolsSpy.log == ["place \(restarted)", Self.show])
    }

    /// In process Chromium answers in the command's turn: the toggle reads only the open state.
    @Test func inProcessTheToggleReadsTheOpenState() async throws {
        let (runtime, root) = try await Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        controller.perform(.toggle)
        controller.perform(.toggle)

        #expect(DevToolsSpy.log == [Self.show, Self.show])
    }

    // MARK: Fixtures

    /// Show, DEVTOOLS_WILL_OPEN, then DEVTOOLS_OPENED docked (a child of the placed view).
    private static func open(_ runtime: CEFRuntime, _ controller: CEFDevToolsController) {
        controller.perform(.show)
        runtime.handle(.devToolsWillOpen(browser: page))
        runtime.handle(.devToolsOpened(browser: page, devTools: devTools, docked: true))
    }

    private static func token(_ page: ChromiumHostPageView) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(page.wireToken))
    }

    /// A runtime that outlives the test (a tab's scheduled work reads it through an unowned
    /// reference); in host mode attached to the spy, whose REPLYs resolve in the host start's table.
    private static func runtime(hostMode: Bool) async throws -> (CEFRuntime, URL) {
        DevToolsSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(DevToolsSpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            runtime.hostStart = try await HostRepliesHarness.attachedHost(over: { DevToolsSpy.symbol($0) })
        }
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A tab whose browser is `page`, its DevTools docked at the bottom (not the remembered layout).
    private static func tab(_ runtime: CEFRuntime) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: page)
        tab.devToolsController.layout = CEFDevToolsLayout()
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        DevToolsSpy.log = []
        DevToolsSpy.placements = []
        return tab
    }

    /// An EncodeFields body with one int32 field (chromium_host_tlv.h: type 1, tag 0, length 4).
    private static func int32(_ value: Int32) -> [UInt8] {
        [1, 0, 4, 0] + withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

/// Records the DevTools changes a tab reports to cmux's focus model.
@MainActor private final class DevToolsObserverSpy: BrowserDevToolsObserving {
    var changes: [(isOpen: Bool, focused: Bool)] = []

    func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool) {
        changes.append((state.isOpen, focused))
    }
}

/// Stand-in shim functions. `devtools_set_key_handler` records whether a handler came; `devtools_set_placement` and `devtools_command` record their calls in
/// order; `browser_set_layer_hosting` records its browser and makes the next reply token current, as
/// the remote shim does for an async op; `fork_api_version` reports 27; every other function does
/// nothing and returns 0.
private nonisolated enum DevToolsSpy {
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var placements: [(browser: Int32, parent: UnsafeMutableRawPointer?, width: Int32, height: Int32)] = []
    nonisolated(unsafe) static var layerHosting: [Int32] = []
    nonisolated(unsafe) static var layerHostingTokens: [UInt32] = []
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    nonisolated(unsafe) static var keyHandlers: [Bool] = []

    static func reset() {
        keyHandlers = []
        log = []
        placements = []
        layerHosting = []
        layerHostingTokens = []
        lastToken = 0
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { DevToolsSpy.lastToken }
        let setKeyHandler: @convention(c) (CEFShimLibrary.KeyFn?) -> Void = { handler in
            DevToolsSpy.keyHandlers.append(handler != nil)
        }
        let setPlacement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = {
            browser, parent, _, _, width, height in
            DevToolsSpy.log.append("place \(browser)")
            DevToolsSpy.placements.append((browser, parent, width, height))
        }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { _, command, _, _ in
            DevToolsSpy.log.append("command \(command)")
            return 1
        }
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, _ in
            DevToolsSpy.layerHosting.append(browser)
            DevToolsSpy.lastToken = 400 + UInt32(DevToolsSpy.layerHostingTokens.count)
            DevToolsSpy.layerHostingTokens.append(DevToolsSpy.lastToken)
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
