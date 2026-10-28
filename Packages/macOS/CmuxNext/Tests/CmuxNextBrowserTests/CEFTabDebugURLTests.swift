@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chromium runs a debug URL (chrome://gpucrash/, chrome://crash/, chrome://hang/) at once and
/// starts no navigation for it (content/browser/renderer_host/navigation_controller_impl.cc,
/// `NavigateWithoutEntry`), so no load start, commit or load end follows. Loading one keeps the tab's page,
/// address and load state, as Chrome's omnibox keeps the committed page; before, the tab stayed loading on the
/// debug URL until a renderer exit ended it, and after chrome://gpucrash/ (no tab's renderer ends) forever.
@MainActor @Suite(.serialized) struct CEFTabDebugURLTests {
    @Test func aDebugURLGoesToChromiumAndKeepsTheLoadedPage() throws {
        let rig = try DebugURLRig()
        defer { rig.close() }
        let tab = try rig.tab()
        let page = try #require(URL(string: "http://127.0.0.1:8080/load.html"))
        tab.load(page)
        let id = try #require(tab.navigation)
        tab.machine.apply(.committed(id, url: page))
        tab.machine.apply(.finished(id))
        try #require(Self.isFinished(tab))
        DebugURLSpy.loads = []

        let debugURLs = ["chrome://gpucrash/", "chrome://crash/", "chrome://hang/"]
        for text in debugURLs {
            tab.load(try #require(URL(string: text)))
            #expect(Self.isFinished(tab), "\(text) left the tab loading, and no load end ever comes for it")
            #expect(tab.state.url == page, "\(text) took the address of the page the tab still shows")
            #expect(tab.navigation == id, "\(text) started a navigation id that Chromium never reports")
        }
        #expect(DebugURLSpy.loads == debugURLs, "Chromium did not get the debug URLs")
    }

    @Test func aPageLoadStillStartsANavigation() throws {
        let rig = try DebugURLRig()
        defer { rig.close() }
        let tab = try rig.tab()
        let settings = try #require(URL(string: "chrome://settings/"))
        tab.load(settings)
        #expect(tab.state.isLoading, "a WebUI page is a navigation")
        #expect(tab.state.url == settings)
        #expect(DebugURLSpy.loads == ["chrome://settings/"])
    }

    @Test func onlyTheExactDebugURLsAreDebugURLs() throws {
        for text in ["chrome://gpucrash/", "chrome://crash", "chrome://Kill/", "CHROME://hang/", "chrome://gpuhang/"] {
            #expect(CEFTab.isDebugURL(try #require(URL(string: text))), "\(text)")
        }
        for text in ["chrome://crash/x", "chrome://crash/?a=1", "chrome://crash/#x", "chrome://settings/", "https://crash/",
                     "chrome://network-error/-106"] {
            #expect(!CEFTab.isDebugURL(try #require(URL(string: text))), "\(text)")
        }
    }

    private static func isFinished(_ tab: CEFTab) -> Bool {
        if case .finished = tab.state.phase { return true }
        return false
    }

    /// A runtime on ``DebugURLSpy``'s shim with one tab whose browser 7 exists (AFTER_CREATED).
    @MainActor final class DebugURLRig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            DebugURLSpy.loads = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-debug-url-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try DebugURLSpy.library(), storage: CEFProfileStorage(root: root))
            // A created tab schedules work that reads its runtime after the test returned.
            _ = Unmanaged.passRetained(runtime)
        }

        func tab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The shim's loads, recorded; `cmux_shim_create_window` reports the window started, every other function does
/// nothing and returns 0.
private nonisolated enum DebugURLSpy {
    nonisolated(unsafe) static var loads: [String] = []

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in DebugURLSpy.loads.append(url.map { String(cString: $0) } ?? "") }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_load_url": unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
