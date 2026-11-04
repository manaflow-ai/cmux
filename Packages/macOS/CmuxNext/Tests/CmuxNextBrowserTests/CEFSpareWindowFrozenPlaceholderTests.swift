@testable import CmuxNextBrowser
import Foundation
import Testing

/// The spare window's placeholder is an about:blank page frozen through DevTools when its browser exists,
/// also on a fork that could make a renderer-less placeholder (`cmux_shim_placeholder_supported` 1):
/// the window is built with `cmux_shim_create_window`, never `cmux_shim_create_placeholder_window`.
/// A pane takes the spare and its tab joins the window; give back and drop keep their behavior.
/// This pins the shipped default (the `rendererlessSpareWindow` feature off) for its removal
/// (prove-or-remove 11-04, row p13-05). Against a spy shim; each test has its own runtime.
@MainActor @Suite(.serialized) struct CEFSpareWindowFrozenPlaceholderTests {
    @Test(arguments: [Int32(24), 29]) func theSpareIsAFrozenAboutBlankPage(forkAPI: Int32) throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: forkAPI)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(FrozenSpareSpy.windowCreates == 1)
        #expect(FrozenSpareSpy.placeholderCreates == 0, "a renderer-less placeholder was built")
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        try Self.comeUp(runtime, browser: 10)

        let blank = try #require(spare.placeholder)
        #expect(blank.browserID == 10)
        #expect(blank.isFrozenSparePlaceholder)
        #expect(runtime.spareWindow.state(of: .browser) == .live)
        #expect(FrozenSpareSpy.devToolsCalls.filter { $0 == "Page.setWebLifecycleState" }.count == 1, "\(FrozenSpareSpy.devToolsCalls)")
    }

    /// The first default-profile pane takes the spare: its tab joins the window with the placeholder as
    /// the anchor, and the placeholder closes on the next turn.
    @Test func aPaneTakesTheSpareAndItsTabJoinsTheWindow() async throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        try Self.comeUp(runtime, browser: 10)

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        #expect(host === spare)
        #expect(runtime.spareWindow.state(of: .browser) == .taken)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(FrozenSpareSpy.tabAddAnchors == [10], "the tab joins the placeholder's window")
        #expect(FrozenSpareSpy.windowCreates == 1 && FrozenSpareSpy.placeholderCreates == 0)
        #expect(tab.browserID == 20)

        for _ in 0..<50 where host.placeholder != nil { await Task.yield() }
        #expect(host.placeholder == nil, "the placeholder stayed after the take")
        #expect(FrozenSpareSpy.closed == [10])
    }

    /// The tab that took the spare closed before it joined: the window is the spare again, with its
    /// frozen placeholder. Dropping it closes the placeholder and the window.
    @Test func giveBackAndDropKeepTheirBehavior() throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)

        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.removed(tab)
        #expect(runtime.spareWindow.host(of: .browser) === host)
        #expect(host.key.pane.rawValue.hasPrefix(CEFSpareWindow.panePrefix))
        let blank = try #require(host.placeholder)
        #expect(blank.isFrozenSparePlaceholder)

        runtime.spareWindow.drop(.browser, runtime: runtime)
        #expect(runtime.spareWindow.host(of: .browser) == nil)
        #expect(host.placeholder == nil)
        #expect(FrozenSpareSpy.closed == [10])
        #expect(!runtime.hosts.values.contains { $0 === host })
    }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn
    /// (`CEFPaneHost.windowCreated`), after the test returned.
    private static func spyRuntime(forkAPI: Int32) throws -> (CEFRuntime, URL) {
        FrozenSpareSpy.reset(forkAPI: forkAPI)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-frozen-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try FrozenSpareSpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim of a fork that has the renderer-less placeholder: window creates, tab adds, closes and
/// DevTools calls are recorded; every other function does nothing and returns 0.
private nonisolated enum FrozenSpareSpy {
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    nonisolated(unsafe) static var windowCreates = 0
    nonisolated(unsafe) static var placeholderCreates = 0
    nonisolated(unsafe) static var tabAddAnchors: [Int32] = []
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var devToolsCalls: [String] = []

    static func reset(forkAPI api: Int32) {
        forkAPI = api
        windowCreates = 0
        placeholderCreates = 0
        tabAddAnchors = []
        closed = []
        devToolsCalls = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { FrozenSpareSpy.forkAPI }
        let supported: @convention(c) () -> Int32 = { 1 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            FrozenSpareSpy.windowCreates += 1
            return 1
        }
        let createPlaceholder: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _ in
            FrozenSpareSpy.placeholderCreates += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, _ in
            FrozenSpareSpy.tabAddAnchors.append(anchor)
            return 20
        }
        let close: @convention(c) (Int32) -> Void = { FrozenSpareSpy.closed.append($0) }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, _ in
            FrozenSpareSpy.devToolsCalls.append(method.map { String(cString: $0) } ?? "")
            return Int32(FrozenSpareSpy.devToolsCalls.count)
        }
        let devToolsSend: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, message in
            FrozenSpareSpy.devToolsCalls.append(message.map { String(cString: $0) } ?? "")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_placeholder_supported": unsafeBitCast(supported, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_placeholder_window": unsafeBitCast(createPlaceholder, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_send": unsafeBitCast(devToolsSend, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
