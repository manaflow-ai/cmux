@testable import CmuxNextBrowser
import Foundation
import Testing

/// p13-webui-055: the built-in uBlock Origin went on `--load-extension`, so Chromium loaded it into
/// every profile at start and Home with no browser tab ran its background page in an extension
/// renderer. With the default-off feature `chromiumAdBlockerAtFirstTab`, on a fork with
/// `cmux_ext_load_command_line`, it stays off the command line and loads into each persistent profile
/// right before that profile's first browser tab: before the window create or the tab add that loads
/// the tab's first page, never for a spare's placeholder or an in-memory store, once per profile.
@MainActor @Suite(.serialized) struct CEFBuiltInExtensionLoadsTests {
    private static let folder = "/Applications/cmux.app/Contents/Resources/Extensions/ublock-origin"

    @Test func atFirstTabTheBuiltInFolderStaysOffTheCommandLine() {
        let arguments = Self.switches(atFirstTab: true)
        #expect(!arguments.contains { $0.hasPrefix("load-extension=") }, "\(arguments)")
        // Its later load is still an unpacked one: the developer-mode policy stays off.
        #expect(arguments.contains("disable-features=ExtensionDisableUnsupportedDeveloper"), "\(arguments)")
    }

    @Test func withoutTheFeatureTheBuiltInFolderLoadsAtStart() {
        let arguments = Self.switches(atFirstTab: false)
        #expect(arguments.contains("load-extension=" + Self.folder), "\(arguments)")
        #expect(CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                    builtInExtensions: [Self.folder]).builtInExtensionsAtFirstTab == false,
                "the feature's default is off")
        #expect(!CEFBuiltInExtensionLoads().featureOn)
    }

    /// Development folders (`CMUX_NEXT_CEF_LOAD_EXTENSIONS`) keep loading at start.
    @Test func developmentFoldersStillLoadAtStart() {
        let arguments = CEFSwitches.current(
            forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next.debug",
            environment: ["CMUX_NEXT_CEF_LOAD_EXTENSIONS": "/tmp/dev-extension"],
            builtInExtensions: [Self.folder], builtInExtensionsAtFirstTab: true, keepsUnpackedEnabled: true
        ).arguments
        #expect(arguments.contains("load-extension=/tmp/dev-extension"), "\(arguments)")
    }

    @Test func eachPersistentProfileLoadsOnceAndInMemoryStoresNever() {
        var loads = CEFBuiltInExtensionLoads()
        loads.started(folders: [Self.folder])
        let pane = BrowserPaneID(rawValue: UUID().uuidString)
        #expect(loads.foldersBeforeTab(of: CEFPaneKey(pane: pane, profile: .default), contextKey: "/p/Default") == [Self.folder])
        #expect(loads.foldersBeforeTab(of: CEFPaneKey(pane: pane, profile: .default), contextKey: "/p/Default").isEmpty)
        let incognito = CEFPaneKey(pane: pane, profile: .default, offTheRecord: true)
        #expect(loads.foldersBeforeTab(of: incognito, contextKey: "otr:1").isEmpty)
        // A new Chromium (a Chromium Host restart) has no profile loaded yet.
        loads.started(folders: [Self.folder])
        #expect(loads.foldersBeforeTab(of: CEFPaneKey(pane: pane, profile: .default), contextKey: "/p/Default") == [Self.folder])
        loads.started(folders: [])
        #expect(loads.foldersBeforeTab(of: CEFPaneKey(pane: pane, profile: .default), contextKey: "/p/Other").isEmpty)
    }

    /// The acceptance check: the extension loads before the first tab's load call, and only then.
    @Test func theFirstTabsWindowCreateComesAfterTheLoad() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.ensureCreated(first)
        let context = runtime.contextKey(for: key)
        #expect(LoadsSpy.calls == ["load \(context) \(Self.folder)", "create"])
        try Self.comeUp(runtime, browser: 10)

        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(second)
        host.ensureCreated(second)
        #expect(LoadsSpy.calls == ["load \(context) \(Self.folder)", "create", "tabAdd"], "the profile loaded twice")
    }

    /// Home's spare window builds no extension renderer; the tab that takes it loads the extension
    /// before it joins the spare's window.
    @Test func theSparePlaceholderLoadsNothingAndTheTabThatTakesItLoadsFirst() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(LoadsSpy.calls == ["create"], "the spare loaded the extension")
        try Self.comeUp(runtime, browser: 10)

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(LoadsSpy.calls == ["create", "load \(runtime.contextKey(for: key)) \(Self.folder)", "tabAdd"])
    }

    @Test func anIncognitoTabLoadsNothing() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default, offTheRecord: true)
        let host = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(LoadsSpy.calls == ["create"])
    }

    /// The feature off, or a fork without the call: the folders went on `--load-extension`, so no tab loads any.
    @Test func withTheFoldersOnTheCommandLineNoTabLoads() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(LoadsSpy.calls == ["create"])
    }

    private static func switches(atFirstTab: Bool) -> [String] {
        CEFSwitches.current(
            forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
            builtInExtensions: [folder], builtInExtensionsAtFirstTab: atFirstTab, keepsUnpackedEnabled: true
        ).arguments
    }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test (a window that came up shows itself at the end of the turn),
    /// started with `folders` to load at first tabs.
    private static func spyRuntime(folders: [String]) throws -> (CEFRuntime, URL) {
        LoadsSpy.calls = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-builtin-loads-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try LoadsSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.builtInLoads.started(folders: folders)
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim: the built-in loads, window creates and tab adds, in call order; every other
/// function does nothing and returns 0.
private nonisolated enum LoadsSpy {
    nonisolated(unsafe) static var calls: [String] = []

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let load: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { context, folder in
            LoadsSpy.calls.append("load \(context.map { String(cString: $0) } ?? "") \(folder.map { String(cString: $0) } ?? "")")
            return 1
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            LoadsSpy.calls.append("create")
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, _ in
            LoadsSpy.calls.append("tabAdd")
            return 20
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_ext_load_command_line": unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
