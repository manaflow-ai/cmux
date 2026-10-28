@testable import CmuxNextBrowser
import Foundation
import Testing

/// The built-in uBlock Origin went on `--load-extension`, so Chromium loaded it into
/// every profile at start and Home with no browser tab ran its background page in an extension
/// renderer. With the default-off feature `chromiumAdBlockerAtFirstTab`, on a fork with
/// `cmux_ext_load_command_line_async`, it stays off the command line and loads into each persistent
/// profile before that profile's first browser tab. The tab asks for its browser (the window create
/// or the `tab_add` that loads its first page) only once the fork answered that the extension is in,
/// never for a spare's placeholder or an in-memory store, once per profile.
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
        #expect(!CEFBuiltInExtensionLoader().featureOn)
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

    /// Only the feature on a fork with the call, with a folder to load, moves the load to first tabs.
    @Test func theLoaderStartsAtFirstTabsOnlyWithTheFeatureTheForkAndAFolder() {
        let loader = CEFBuiltInExtensionLoader()
        #expect(loader.start([Self.folder], forkSupports: true) != .atFirstTab, "feature off")
        loader.featureOn = true
        #expect(loader.start([Self.folder], forkSupports: false) != .atFirstTab, "an old fork")
        #expect(loader.start([], forkSupports: true) != .atFirstTab, "nothing to load")
        #expect(loader.loads.folders.isEmpty)
        #expect(loader.start([Self.folder], forkSupports: true) == .atFirstTab)
        #expect(loader.loads.folders == [Self.folder])
    }

    @Test func eachPersistentProfileLoadsOnceAndInMemoryStoresNever() {
        var loads = CEFBuiltInExtensionLoads()
        loads.started(folders: [Self.folder, "/second"])
        let pane = BrowserPaneID(rawValue: UUID().uuidString)
        let key = CEFPaneKey(pane: pane, profile: .default)
        #expect(loads.gate(key, contextKey: "/p/Default") == .start([Self.folder, "/second"]))
        #expect(loads.gate(key, contextKey: "/p/Default") == .waiting)
        #expect(loads.gate(CEFPaneKey(pane: pane, profile: .default, offTheRecord: true), contextKey: "otr:1") == .open)
        let first = loads.generation
        // `answered` is mutating, so each result goes into a local: #expect's call form takes an immutable `$0`.
        let oneFolderLeft = loads.answered(contextKey: "/p/Default", generation: first)
        #expect(!oneFolderLeft, "one folder still loads")
        let lastFolder = loads.answered(contextKey: "/p/Default", generation: first)
        #expect(lastFolder, "the profile's last folder")
        #expect(loads.gate(key, contextKey: "/p/Default") == .open)
        let answeredAgain = loads.answered(contextKey: "/p/Default", generation: first)
        #expect(!answeredAgain, "a profile answers once")
        // A new Chromium (a Chromium Host restart) has no profile loaded yet, and the old one's answers change nothing.
        loads.started(folders: [Self.folder])
        #expect(loads.gate(key, contextKey: "/p/Default") == .start([Self.folder]))
        let staleAnswer = loads.answered(contextKey: "/p/Default", generation: first)
        #expect(!staleAnswer)
        #expect(loads.gate(key, contextKey: "/p/Default") == .waiting)
        loads.started(folders: [])
        #expect(loads.gate(key, contextKey: "/p/Other") == .open)
    }

    /// The acceptance check on a pane with no window: the window create, which loads the first page,
    /// comes only after the fork answered the load; a tab shown meanwhile joins that window.
    @Test func theFirstTabsWindowCreateWaitsForTheLoadsAnswer() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        let turns = TurnQueue(host)
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.ensureCreated(first)
        let context = runtime.contextKey(for: key)
        #expect(LoadsSpy.calls == ["load \(context) \(Self.folder)"], "nothing navigates before the extension is in")
        #expect(host.window == .awaitingExtensions && first.isCreationPending)

        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(second)
        host.ensureCreated(second)
        #expect(LoadsSpy.calls.count == 1, "the profile loads once")

        try Self.answer(runtime, loaded: true)
        turns.endTurns()
        #expect(LoadsSpy.calls == ["load \(context) \(Self.folder)", "create"])
        try Self.comeUp(runtime, browser: 10)
        #expect(LoadsSpy.calls == ["load \(context) \(Self.folder)", "create", "tabAdd"])

        let third = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(third)
        host.ensureCreated(third)
        #expect(LoadsSpy.calls.last == "tabAdd" && LoadsSpy.calls.count == 4, "a loaded profile's tabs never wait")
    }

    /// The judge's case: Home's spare window builds no extension renderer, and the first tab takes it
    /// with `tab_add`, which navigates in the call. The tab joins only after the fork's answer.
    @Test func theTabThatTakesTheSpareJoinsOnlyAfterTheLoadsAnswer() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        #expect(LoadsSpy.calls == ["create"], "the spare loaded the extension")
        try Self.comeUp(runtime, browser: 10)

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        let turns = TurnQueue(host)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let load = "load \(runtime.contextKey(for: key)) \(Self.folder)"
        #expect(LoadsSpy.calls == ["create", load], "no tab_add before the extension is in")
        #expect(host.isLive && tab.isCreationPending && tab.browserID == nil)

        try Self.answer(runtime, loaded: true)
        turns.endTurns()
        #expect(LoadsSpy.calls == ["create", load, "tabAdd"])
        #expect(tab.browserID == LoadsSpy.addedBrowser)
    }

    /// A load the fork could not do still opens the tab, without the extension.
    @Test func aFailedLoadStillOpensTheTab() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let turns = TurnQueue(host)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        try Self.answer(runtime, loaded: false)
        turns.endTurns()
        #expect(LoadsSpy.calls.last == "create")
    }

    /// The shim refused the load (no reply comes): the tab does not wait for one.
    @Test func aRefusedLoadDoesNotHoldTheTab() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        LoadsSpy.loadResult = 0
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let turns = TurnQueue(host)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        turns.endTurns()
        #expect(LoadsSpy.calls.last == "create")
    }

    /// A Chromium Host restart: the tab that waited asks the new Chromium, which loads again; the old
    /// Chromium's late answer does not open it.
    @Test func aRestartedChromiumLoadsAgainForTheWaitingTab() throws {
        let (runtime, root) = try Self.spyRuntime(folders: [Self.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let turns = TurnQueue(host)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let old = try #require(LoadsSpy.replies.first)
        #expect(runtime.builtInLoader.start([Self.folder], forkSupports: true) == .atFirstTab)
        turns.endTurns()
        #expect(LoadsSpy.calls.count == 2 && !LoadsSpy.calls.contains("create"))

        runtime.handle(.reply(browser: 0, id: old, value: 1, json: ""))
        turns.endTurns()
        #expect(!LoadsSpy.calls.contains("create"), "the old Chromium's answer")
        try Self.answer(runtime, loaded: true)
        turns.endTurns()
        #expect(LoadsSpy.calls.last == "create")
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

    /// The fork's CMUX_SHIM_REPLY to the last load the spy took.
    private static func answer(_ runtime: CEFRuntime, loaded: Bool) throws {
        let id = try #require(LoadsSpy.replies.last)
        runtime.handle(.reply(browser: 0, id: id, value: loaded ? 1 : 0, json: ""))
    }

    /// A runtime that outlives the test (a window that came up shows itself at the end of the turn),
    /// started with `folders` to load at first tabs.
    private static func spyRuntime(folders: [String]) throws -> (CEFRuntime, URL) {
        LoadsSpy.calls = []
        LoadsSpy.replies = []
        LoadsSpy.loadResult = 1
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-builtin-loads-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try LoadsSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.builtInLoader.featureOn = true
        _ = runtime.builtInLoader.start(folders, forkSupports: true)
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// A pane host's end-of-turn blocks, run when the test says the turn ended.
@MainActor private final class TurnQueue {
    private var blocks: [@MainActor @Sendable () -> Void] = []

    init(_ host: CEFPaneHost) {
        host.endOfTurn = { [weak self] block in self?.blocks.append(block) }
    }

    /// Ends the turns the pane host scheduled, and the turns those schedule (a bounded number).
    func endTurns() {
        for _ in 0..<20 where !blocks.isEmpty {
            let due = blocks
            blocks.removeAll()
            for block in due { block() }
        }
    }
}

/// Stand-in shim: the built-in loads, window creates and tab adds, in call order; every other
/// function does nothing and returns 0.
private nonisolated enum LoadsSpy {
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var replies: [Int32] = []
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var loadResult: Int32 = 1
    static let addedBrowser: Int32 = 20

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let load: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32 = { context, reply, folder in
            LoadsSpy.calls.append("load \(context.map { String(cString: $0) } ?? "") \(folder.map { String(cString: $0) } ?? "")")
            LoadsSpy.replies.append(reply)
            return LoadsSpy.loadResult
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            LoadsSpy.calls.append("create")
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, _ in
            LoadsSpy.calls.append("tabAdd")
            return LoadsSpy.addedBrowser
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
