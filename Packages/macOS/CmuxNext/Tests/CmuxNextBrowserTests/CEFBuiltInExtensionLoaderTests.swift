import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Decision d-e4f491bbb4: the built-in uBlock Origin loads when a profile's first web tab opens, not at
/// the app's launch (about 74 MB less at idle), and that tab's first navigation waits until it is ready,
/// so no page ever loads unblocked. `create_window` navigates in the call, so the wait is before it.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFBuiltInExtensionLoaderTests {
    static let address = URL(string: "https://example.com/")!
    static let folder = "/Applications/cmux.app/Contents/Resources/Extensions/ublock-origin"

    @Test func theFirstTabsNavigationWaitsForTheBlocker() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.builtInLoader.begin([Self.folder], forkSupports: true) == .atFirstTab)

        let (host, tab, _) = Self.shownTab(runtime)
        #expect(BlockerSpy.createdURLs.isEmpty, "no page navigates before the blocker is ready")
        #expect(BlockerSpy.loads.map(\.path) == [Self.folder], "the first tab starts the blocker's load")
        #expect(BlockerSpy.loads.map(\.context) == [runtime.contextKey(for: host.key)], "into the tab's own profile")
        #expect(tab.awaitsBuiltInExtensions)

        // A second tab of the profile asks meanwhile: it waits too, and starts no second load.
        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        second.load(Self.address)
        host.add(second)
        host.ensureCreated(second)
        #expect(BlockerSpy.loads.count == 1)
        #expect(BlockerSpy.createdURLs.isEmpty)

        let reply = try #require(BlockerSpy.loads.first?.reply)
        runtime.handle(.reply(browser: 0, id: reply, value: 1, json: ""))
        #expect(BlockerSpy.createdURLs == [Self.address.absoluteString], "the shown tab navigates once the blocker answered")
        #expect(!tab.awaitsBuiltInExtensions && !second.awaitsBuiltInExtensions)
        #expect(tab.isCreationPending && second.isCreationPending, "the second tab joins the window being built")

        // The profile has its blocker now: the next tab asks at once, with no load.
        let third = CEFTab(id: .random(), profile: .default, host: runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: "other"), profile: .default)), runtime: runtime)
        third.load(Self.address)
        third.host.add(third)
        third.host.ensureCreated(third)
        #expect(BlockerSpy.loads.count == 1)
        #expect(BlockerSpy.createdURLs.count == 2)
    }

    @Test func aLoadTheShimRefusesOpensTheTabAtOnce() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        BlockerSpy.loadAnswer = 0
        runtime.builtInLoader.begin([Self.folder], forkSupports: true)
        _ = Self.shownTab(runtime)
        #expect(BlockerSpy.loads.count == 1)
        #expect(BlockerSpy.createdURLs == [Self.address.absoluteString], "a refused load never leaves the pane blank")
    }

    @Test func aForkWithoutTheLaterLoadKeepsItAtStart() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.builtInLoader.begin([Self.folder], forkSupports: false) == .atStart)
        _ = Self.shownTab(runtime)
        #expect(BlockerSpy.loads.isEmpty, "it loaded through --load-extension at start")
        #expect(BlockerSpy.createdURLs == [Self.address.absoluteString])
    }

    @Test func anIncognitoTabNeverWaits() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        runtime.builtInLoader.begin([Self.folder], forkSupports: true)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default, offTheRecord: true),
                               runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.load(Self.address)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(BlockerSpy.loads.isEmpty)
        #expect(BlockerSpy.createdURLs == [Self.address.absoluteString])
    }

    @Test func theLoadsCountPerProfileAndPerStart() {
        var loads = CEFBuiltInExtensionLoads()
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: "p"), profile: .default)
        #expect(loads.gate(key, contextKey: "a") == .open, "nothing to load before a start")
        loads.started(folders: ["x", "y"])
        #expect(loads.gate(key, contextKey: "a") == .start(["x", "y"]))
        #expect(loads.gate(key, contextKey: "a") == .waiting)
        #expect(!loads.answered(contextKey: "a", generation: loads.generation))
        #expect(loads.answered(contextKey: "a", generation: loads.generation), "the last folder's answer opens the profile")
        #expect(loads.gate(key, contextKey: "a") == .open)
        #expect(loads.gate(key, contextKey: "b") == .start(["x", "y"]), "each profile loads its own")
        let old = loads.generation
        loads.started(folders: ["x"])
        #expect(!loads.answered(contextKey: "b", generation: old), "an earlier Chromium's answer changes nothing")
    }

    // MARK: Helpers

    static func runtime() throws -> (CEFRuntime, URL) {
        BlockerSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-blocker-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try BlockerSpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        runtime.builtInLoader.prepareContext = { _, then in then() }
        return (runtime, root)
    }

    /// A pane showing a new tab of the default profile that opens `address`.
    static func shownTab(_ runtime: CEFRuntime) -> (CEFPaneHost, CEFTab, NSView) {
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.load(address)
        host.add(tab)
        host.present(tab, in: container)
        host.createDeferred()
        return (host, tab, container)
    }
}

/// Stand-in shim: `cmux_shim_create_window` records its URL, `cmux_shim_ext_load_command_line` records
/// its load and answers `loadAnswer`, `cmux_shim_ext_load_later_supported` answers 1; every other
/// function does nothing and returns 0.
nonisolated enum BlockerSpy {
    nonisolated(unsafe) static var createdURLs: [String] = []
    nonisolated(unsafe) static var loads: [(context: String, reply: Int32, path: String)] = []
    nonisolated(unsafe) static var loadAnswer: Int32 = 1

    static func reset() {
        createdURLs = []
        loads = []
        loadAnswer = 1
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, url, _ in
            BlockerSpy.createdURLs.append(url.map { String(cString: $0) } ?? "")
            return 1
        }
        let load: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32 = { context, reply, path in
            BlockerSpy.loads.append((context.map { String(cString: $0) } ?? "", reply, path.map { String(cString: $0) } ?? ""))
            return BlockerSpy.loadAnswer
        }
        let supported: @convention(c) () -> Int32 = { 1 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_ext_load_command_line": unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_ext_load_later_supported": unsafeBitCast(supported, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
