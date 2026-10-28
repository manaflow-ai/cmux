@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chrome keeps one spare renderer (`SpareRenderProcessHostManager`). Home had two or
/// three: the default profile's spare window holds an about:blank placeholder with a renderer, the pages
/// spare window another, and Chromium kept its own spare beside them. With the default-off feature
/// `chromiumOneSpareRenderer` there is one: while placeholders hold a renderer, Chromium's own spare is
/// off (`disable-features=SpareRendererForSitePerProcess`) and only the default profile keeps a spare
/// window; with renderer-less placeholders Chromium's spare is the one and every kind keeps its window.
/// Each spare window reports its placeholder's renderer for `debug.memory`. Against a spy shim; each
/// test has its own runtime.
@MainActor @Suite(.serialized) struct CEFOneSpareRendererTests {
    private let pages = BrowserProfileID(rawValue: UUID())

    // MARK: Switches

    @Test func chromiumSpareOffDisablesChromiumsSpareInTheOneDisableEntry() {
        let switches = CEFSwitches.current(forkAPIVersion: 29, disabledChromiumFeatures: ["MediaRouter"], chromiumSpareOff: true,
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        let disables = switches.arguments.filter { $0.hasPrefix("disable-features=") }
        let expected = CEFSwitches.idleServiceOffFeatures + ["MediaRouter", CEFSwitches.spareRendererFeature]
        #expect(disables == ["disable-features=" + expected.joined(separator: ",")], "\(switches.arguments)")
        #expect(!switches.enabledFeatures.contains(CEFSwitches.spareRendererFeature))
    }

    @Test func chromiumSpareOnPassesNothing() {
        let switches = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.arguments.contains { $0.contains(CEFSwitches.spareRendererFeature) }, "\(switches.arguments)")
    }

    @Test func theAppsOwnDisableOfTheSameFeatureIsNotRepeated() {
        let switches = CEFSwitches.current(forkAPIVersion: 29, disabledChromiumFeatures: [CEFSwitches.spareRendererFeature],
                                           chromiumSpareOff: true, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(switches.disabledFeatures == CEFSwitches.idleServiceOffFeatures + [CEFSwitches.spareRendererFeature])
    }

    // MARK: The spare windows

    /// Feature off: Chromium keeps its own spare and both kinds keep a spare window, as before.
    @Test func featureOffKeepsChromiumsSpareAndBothWindows() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = wantingPages(runtime)
        #expect(spares.chromiumStarting(placeholderSupported: false))
        #expect(!spares.placeholderIsTheSpare)
        #expect(spares.wantedKinds == [.browser, .pages])
    }

    /// Feature on, placeholders with a renderer (the feature `rendererlessSpareWindow` off, or a fork
    /// without renderer-less placeholders): the default profile's placeholder is the one spare renderer.
    @Test(arguments: [(false, false), (false, true), (true, false)])
    func placeholdersWithARendererAreTheOneSpare(rendererless: Bool, supported: Bool) throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = wantingPages(runtime)
        spares.oneSpareRenderer = true
        spares.rendererlessPlaceholders = rendererless
        #expect(!spares.chromiumStarting(placeholderSupported: supported), "Chromium kept its own spare beside the placeholder")
        #expect(spares.wantedKinds == [.browser])

        #expect(!spares.prepare(.pages, runtime: runtime), "a second placeholder renderer")
        #expect(spares.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)
        #expect(spares.state(of: .browser) == .live)
        #expect(spares.missingKind == nil, "the warmup would ask for a pages spare")
        #expect(OneSpareSpy.createWindowCalls == 1)
        #expect(spares.untakenSpares.map { $0.kind } == [.browser])
        #expect(spares.untakenSpares.first?.rendererClients == [110], "the placeholder's renderer is not reported")
    }

    /// Feature on with renderer-less placeholders: Chromium's own spare is the one, and both kinds keep
    /// a window, which holds no renderer.
    @Test func rendererlessPlaceholdersKeepChromiumsSpare() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = wantingPages(runtime)
        spares.oneSpareRenderer = true
        spares.rendererlessPlaceholders = true
        #expect(spares.chromiumStarting(placeholderSupported: true))
        #expect(!spares.placeholderIsTheSpare)
        #expect(spares.wantedKinds == [.browser, .pages])
    }

    /// A Chromium restart on a fork that lost renderer-less placeholders follows the new fork.
    @Test func eachStartDecidesAgain() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = wantingPages(runtime)
        spares.oneSpareRenderer = true
        spares.rendererlessPlaceholders = true
        #expect(spares.chromiumStarting(placeholderSupported: true))
        #expect(!spares.chromiumStarting(placeholderSupported: false))
        #expect(spares.wantedKinds == [.browser])
    }

    // MARK: Helpers

    private func wantingPages(_ runtime: CEFRuntime) -> CEFSpareWindow {
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        spares.setWantsPages(true, runtime: runtime)
        return spares
    }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn
    /// (`CEFPaneHost.windowCreated`), after the test returned.
    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        OneSpareSpy.createWindowCalls = 0
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-one-spare-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try OneSpareSpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim: `cmux_shim_create_window` counts its calls and starts the browser, and each browser
/// runs in renderer client `browser + 100`; every other function does nothing and returns 0.
private nonisolated enum OneSpareSpy {
    nonisolated(unsafe) static var createWindowCalls = 0

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            OneSpareSpy.createWindowCalls += 1
            return 1
        }
        let rendererClients: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32 = { browser, ids, room in
            guard let ids, room > 0 else { return 0 }
            unsafe ids.pointee = browser + 100
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_renderer_client_ids": unsafeBitCast(rendererClients, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
