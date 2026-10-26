import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 024 of plans/cmux-next/chrome-parity/p01-process.md: in host mode a tab's DevTools is a
/// hosted context. Its placement names the token of the tab's DevTools `ChromiumHostPageView` and
/// goes before the command that may open DevTools (the host does not wait for DEVTOOLS_WILL_OPEN);
/// the page view shows the context id of the host's REPLY, docked in the pane or in the DevTools
/// panel; a DevTools nothing placed closes and opens again placed. In process the placement stays
/// inside DEVTOOLS_WILL_OPEN with the docked host view's pointer.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFDevToolsHostedPlacementTests {
    private static let page: Int32 = 1
    private static let devTools: Int32 = 2

    // MARK: Placement

    @Test func hostModePlacesTheHostedPageViewBeforeTheOpenCommand() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
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

    @Test func eachOpeningCommandPlacesFirst() throws {
        for command in [BrowserDevToolsCommand.show, .console, .inspectElement, .toggle] {
            let (runtime, root) = try Self.runtime(hostMode: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tab = Self.tab(runtime)
            tab.devToolsController.perform(command)
            #expect(DevToolsSpy.log.first == "place \(Self.page)", "\(command) asked for DevTools unplaced")
        }
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        tab.devToolsController.perform(.close)
        #expect(DevToolsSpy.placements.isEmpty, "closing needs no placement")
    }

    @Test func inProcessThePlacementStaysInWillOpenWithTheHostViewPointer() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(tab.container)
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        controller.perform(.show)
        #expect(DevToolsSpy.placements.isEmpty, "in process the placement waits for DEVTOOLS_WILL_OPEN")

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        let views = try #require(controller.views)
        #expect(DevToolsSpy.placements.map(\.parent) == [Unmanaged.passUnretained(views.host).toOpaque()])
        #expect(controller.hostedPage == nil, "no hosted page view in process")
    }

    // MARK: Context

    @Test func hostModeADockedDevToolsShowsTheContextOfTheHostsReply() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try #require(runtime.hostReplies)
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
        route.replies.resolve(DevToolsSpy.layerHostingTokens[0], fields: Self.int32(Int32(bitPattern: 0x8000_0024)))
        #expect(hosted.contextID == 0x8000_0024)
    }

    @Test func hostModeAReplyAfterTheDevToolsClosedShowsNothing() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try #require(runtime.hostReplies)
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        Self.open(runtime, controller)
        let hosted = try #require(controller.hostedPage)

        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        route.replies.resolve(DevToolsSpy.layerHostingTokens[0], fields: Self.int32(77))

        #expect(hosted.contextID == 0)
        #expect(!tab.devTools.isOpen)
        #expect(controller.hostedPlacement == nil)
    }

    /// The host drops a placement when its DevTools closes, so the next open places again, with the
    /// same page view token (one host view per tab, never one per open).
    @Test func hostModeTheNextOpenPlacesAgainWithTheSameToken() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        Self.open(runtime, controller)
        let hosted = try #require(controller.hostedPage)
        hosted.show(contextID: 5)
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(hosted.contextID == 0, "a closed DevTools' context stayed shown")

        Self.open(runtime, controller)

        #expect(controller.hostedPage === hosted)
        #expect(DevToolsSpy.placements.map(\.parent) == [Self.token(hosted), Self.token(hosted)])
        #expect(hosted.superview === controller.views?.host)
    }

    @Test func hostModeAnUndockedDevToolsShowsInTheDevToolsPanel() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
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

    // MARK: Unplaced

    /// An open the host started (no placement yet) lands in a window of the host's own, which never
    /// shows: cmux closes it and opens it again, placed.
    @Test func hostModeAnUnplacedDevToolsClosesAndOpensAgainPlaced() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        #expect(!controller.reservesRoom, "an unplaced DevTools is not in the pane")
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        #expect(!tab.devTools.isOpen)
        #expect(DevToolsSpy.log == ["command \(CEFShimLibrary.DevToolsCommand.close)"])

        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        #expect(DevToolsSpy.log == ["command \(CEFShimLibrary.DevToolsCommand.close)", "place \(Self.page)",
                                    "command \(CEFShimLibrary.DevToolsCommand.show)"])
    }

    /// A placed DevTools that still opened in a window of its own closes and stays closed: opening
    /// it again would loop.
    @Test func hostModeAPlacedDevToolsOutsideItsPlacementStaysClosed() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let controller = tab.devToolsController
        controller.perform(.show)
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))

        #expect(DevToolsSpy.log == ["place \(Self.page)", "command \(CEFShimLibrary.DevToolsCommand.show)",
                                    "command \(CEFShimLibrary.DevToolsCommand.close)"])
        #expect(!tab.devTools.isOpen)
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
    /// reference); in host mode with a reply route over the host start's table.
    private static func runtime(hostMode: Bool) throws -> (CEFRuntime, URL) {
        DevToolsSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(DevToolsSpy.symbol), storage: CEFProfileStorage(root: root))
        if hostMode {
            let hostStart = CEFHostStart(supervisor: NoDevToolsHost())
            runtime.hostStart = hostStart
            runtime.hostReplies = try CEFHostReplyRoute(symbol: DevToolsSpy.symbol, replies: hostStart.replies)
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

/// Never attaches: these tests drive DevTools against the spy shim and never start Chromium.
@MainActor private final class NoDevToolsHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// Stand-in shim functions. `devtools_set_placement` and `devtools_command` record their calls in
/// order; `browser_set_layer_hosting` records its browser and makes the next reply token current, as
/// the remote shim does for an async op; `fork_api_version` reports 27; every other function does
/// nothing and returns 0.
private nonisolated enum DevToolsSpy {
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var placements: [(browser: Int32, parent: UnsafeMutableRawPointer?, width: Int32, height: Int32)] = []
    nonisolated(unsafe) static var layerHosting: [Int32] = []
    nonisolated(unsafe) static var layerHostingTokens: [UInt32] = []
    nonisolated(unsafe) static var lastToken: UInt32 = 0

    static func reset() {
        log = []
        placements = []
        layerHosting = []
        layerHostingTokens = []
        lastToken = 0
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFHostReplyRoute.LastReplyTokenFn = { DevToolsSpy.lastToken }
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
        case "cmux_shim_devtools_set_placement": unsafeBitCast(setPlacement, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
