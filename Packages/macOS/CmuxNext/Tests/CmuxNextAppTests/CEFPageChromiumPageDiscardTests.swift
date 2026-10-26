import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// p13-webui-031: a cmux page in Chromium discards through its tab's in-place discard, and only the
/// next load after a discard that took reloads the discarded entry; a fork without the export
/// answers false so the page host closes the page. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFPageChromiumPageDiscardTests {
    @Test func theLoadAfterADiscardReloadsInPlaceAndTheOneAfterNavigates() throws {
        let rig = try PageDiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let page = try rig.page()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))

        #expect(page.discard())
        PageDiscardSpy.loads = []
        page.load(route)
        #expect(PageDiscardSpy.reloads == [7], "the discarded entry did not reload in place")
        #expect(PageDiscardSpy.loads.isEmpty)

        page.load(route)
        #expect(PageDiscardSpy.loads == [route.absoluteString], "a load with no discard before it is a navigation")
        #expect(PageDiscardSpy.reloads == [7])
    }

    @Test func aForkWithoutTheExportRefusesAndTheNextLoadNavigates() throws {
        let rig = try PageDiscardRig(exportsDiscard: false)
        defer { rig.close() }
        let page = try rig.page()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))

        #expect(!page.discard())
        PageDiscardSpy.loads = []
        page.load(route)
        #expect(PageDiscardSpy.loads == [route.absoluteString])
        #expect(PageDiscardSpy.reloads.isEmpty)
    }

    @Test func aClosedPageDiscardsNothing() throws {
        let rig = try PageDiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let page = try rig.page()
        page.close()
        #expect(!page.discard())
        #expect(PageDiscardSpy.discarded.isEmpty)
    }

    @MainActor final class PageDiscardRig {
        let runtime: CEFRuntime
        let root: URL

        init(exportsDiscard: Bool) throws {
            PageDiscardSpy.reset(exportsDiscard: exportsDiscard)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try PageDiscardSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A page whose tab's browser 7 exists (AFTER_CREATED).
        func page() throws -> CEFPageChromiumPage {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return CEFPageChromiumPage(tab: tab, pageID: "cmux.markdown")
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The shim's discard, load and reload calls, recorded; every other function does nothing.
private nonisolated enum PageDiscardSpy {
    nonisolated(unsafe) static var exportsDiscard = true
    nonisolated(unsafe) static var discarded: [Int32] = []
    nonisolated(unsafe) static var loads: [String] = []
    nonisolated(unsafe) static var reloads: [Int32] = []

    static func reset(exportsDiscard exports: Bool) {
        exportsDiscard = exports
        discarded = []
        loads = []
        reloads = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let discard: @convention(c) (Int32) -> Int32 = { browser in PageDiscardSpy.discarded.append(browser); return 1 }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in PageDiscardSpy.loads.append(url.map { String(cString: $0) } ?? "") }
        let reload: @convention(c) (Int32) -> Void = { browser in PageDiscardSpy.reloads.append(browser) }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            if name == "cmux_shim_tab_discard" {
                return PageDiscardSpy.exportsDiscard ? unsafeBitCast(discard, to: UnsafeMutableRawPointer.self) : nil
            }
            return switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_load_url": unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_reload": unsafeBitCast(reload, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
