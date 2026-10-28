@testable import CmuxNextBrowser
import Foundation
import Testing

/// With the `rendererlessSpareWindow` feature (`CEFSpareWindow.rendererlessPlaceholders`),
/// where the fork makes renderer-less placeholders (`cmux_shim_placeholder_supported`),
/// a spare window's first tab is made with no renderer and no navigation (Chrome's `kNoRendererProcess`,
/// `chrome/browser/ui/browser_tabrestore.cc`), so the spare sends no DevTools call: no page setup and
/// no `freezeNeverShownPage`. Take, give back and drop work as before. With the feature off, or on a
/// fork without the placeholder, the spare keeps the about:blank page frozen through DevTools.
/// Against a spy shim; each test has its own runtime.
@MainActor @Suite(.serialized) struct CEFSpareWindowRendererlessTests {
    /// Every DevTools call is counted: on fork API 24 a page's attach opens a DevTools session, on 29
    /// it does not, and neither may reach the spare.
    @Test(arguments: [Int32(24), 29]) func theSpareHasNoRendererAndSendsNoDevToolsCall(forkAPI: Int32) throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: forkAPI)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(RendererlessSpy.placeholderCreates == 1)
        #expect(RendererlessSpy.windowCreates == 0, "the about:blank window was built")
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        try Self.comeUp(runtime, browser: 10)

        let blank = try #require(spare.placeholder)
        #expect(blank.browserID == 10)
        #expect(blank.isRendererlessPlaceholder)
        #expect(runtime.spareWindow.state(of: .browser) == .live)
        #expect(RendererlessSpy.devToolsCalls.isEmpty, "\(RendererlessSpy.devToolsCalls)")
        #expect(RendererlessSpy.frozen.isEmpty, "a page with no renderer was frozen")
    }

    /// The first default-profile pane takes the spare: its tab joins the window with the placeholder as
    /// the anchor, and the placeholder closes on the next turn, as before.
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
        #expect(RendererlessSpy.tabAddAnchors == [10], "the tab joins the placeholder's window")
        #expect(RendererlessSpy.windowCreates == 0 && RendererlessSpy.placeholderCreates == 1)
        #expect(tab.browserID == 20)

        for _ in 0..<50 where host.placeholder != nil { await Task.yield() }
        #expect(host.placeholder == nil, "the placeholder stayed after the take")
        #expect(RendererlessSpy.closed == [10])
    }

    /// The tab that took the spare closed before it joined: the window is the spare again, still with
    /// its renderer-less placeholder. Dropping it closes the placeholder and the window.
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
        #expect(blank.isRendererlessPlaceholder)
        #expect(RendererlessSpy.devToolsCalls.isEmpty)

        runtime.spareWindow.drop(.browser, runtime: runtime)
        #expect(runtime.spareWindow.host(of: .browser) == nil)
        #expect(host.placeholder == nil)
        #expect(RendererlessSpy.closed == [10])
        #expect(!runtime.hosts.values.contains { $0 === host })
    }

    /// A fork without the placeholder: the about:blank window, frozen through DevTools when its browser exists.
    @Test func aForkWithoutThePlaceholderKeepsTheFrozenAboutBlankPage() throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29, supported: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(RendererlessSpy.windowCreates == 1 && RendererlessSpy.placeholderCreates == 0)
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        try Self.comeUp(runtime, browser: 10)
        #expect(spare.placeholder?.isRendererlessPlaceholder == false)
        #expect(RendererlessSpy.devToolsCalls.filter { $0 == "Page.setWebLifecycleState" }.count == 1, "\(RendererlessSpy.devToolsCalls)")
    }

    /// The feature off (its default) on a fork that has the placeholder: the about:blank window, frozen
    /// through DevTools when its browser exists, as before p13-webui-019.
    @Test func theFeatureOffKeepsTheFrozenAboutBlankPage() throws {
        #expect(!CEFSpareWindow().rendererlessPlaceholders, "the feature's default is off")
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29, feature: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(RendererlessSpy.windowCreates == 1 && RendererlessSpy.placeholderCreates == 0)
        let spare = try #require(runtime.spareWindow.host(of: .browser))
        try Self.comeUp(runtime, browser: 10)
        #expect(spare.placeholder?.isRendererlessPlaceholder == false)
        #expect(RendererlessSpy.devToolsCalls.filter { $0 == "Page.setWebLifecycleState" }.count == 1, "\(RendererlessSpy.devToolsCalls)")
    }

    /// Only a spare's own placeholder is made renderer-less: a pane's window, or a popup host's
    /// placeholder, is built as before.
    @Test func aWindowThatIsNoSpareIsBuiltAsBefore() throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let blank = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.placeholder = blank
        host.add(blank)
        host.ensureCreated(blank)
        #expect(RendererlessSpy.windowCreates == 1 && RendererlessSpy.placeholderCreates == 0)
        try Self.comeUp(runtime, browser: 10)
        #expect(!blank.isRendererlessPlaceholder)
    }

    /// The spare's window coming up marks `cef.spare_window_ready`, once per process: not
    /// while it is being built, and not again when it comes back to the spare or a later spare comes up.
    @Test func theSparesWindowMarksSpareWindowReadyOnce() throws {
        let (runtime, root) = try Self.spyRuntime(forkAPI: 29)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(log.names.isEmpty, "marked before the window came up")
        try Self.comeUp(runtime, browser: 10)
        #expect(log.names == ["cef.spare_window_ready"])

        runtime.spareWindow.drop(.browser, runtime: runtime)
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 11)
        #expect(log.names == ["cef.spare_window_ready"])
    }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn
    /// (`CEFPaneHost.windowCreated`), after the test returned.
    /// `feature` is the `rendererlessSpareWindow` feature (`CEFEngine.setRendererlessSpareWindows`).
    private static func spyRuntime(forkAPI: Int32, supported: Bool = true, feature: Bool = true) throws -> (CEFRuntime, URL) {
        RendererlessSpy.reset(forkAPI: forkAPI, supported: supported)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-rendererless-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try RendererlessSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.spareWindow.rendererlessPlaceholders = feature
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim: window creates, tab adds, closes, freezes and DevTools calls are recorded; every
/// other function does nothing and returns 0.
private nonisolated enum RendererlessSpy {
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    nonisolated(unsafe) static var supported = true
    nonisolated(unsafe) static var windowCreates = 0
    nonisolated(unsafe) static var placeholderCreates = 0
    nonisolated(unsafe) static var tabAddAnchors: [Int32] = []
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var frozen: [Int32] = []
    nonisolated(unsafe) static var devToolsCalls: [String] = []

    static func reset(forkAPI api: Int32, supported isSupported: Bool) {
        forkAPI = api
        supported = isSupported
        windowCreates = 0
        placeholderCreates = 0
        tabAddAnchors = []
        closed = []
        frozen = []
        devToolsCalls = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { RendererlessSpy.forkAPI }
        let supported: @convention(c) () -> Int32 = { RendererlessSpy.supported ? 1 : 0 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            RendererlessSpy.windowCreates += 1
            return 1
        }
        let createPlaceholder: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _ in
            guard RendererlessSpy.supported else { return 0 }
            RendererlessSpy.placeholderCreates += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, _ in
            RendererlessSpy.tabAddAnchors.append(anchor)
            return 20
        }
        let close: @convention(c) (Int32) -> Void = { RendererlessSpy.closed.append($0) }
        let freeze: @convention(c) (Int32, Int32) -> Int32 = { browser, _ in RendererlessSpy.frozen.append(browser); return 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, _ in
            RendererlessSpy.devToolsCalls.append(method.map { String(cString: $0) } ?? "")
            return Int32(RendererlessSpy.devToolsCalls.count)
        }
        let devToolsSend: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, message in
            RendererlessSpy.devToolsCalls.append(message.map { String(cString: $0) } ?? "")
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
            case "cmux_shim_tab_set_frozen": unsafeBitCast(freeze, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_send": unsafeBitCast(devToolsSend, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
