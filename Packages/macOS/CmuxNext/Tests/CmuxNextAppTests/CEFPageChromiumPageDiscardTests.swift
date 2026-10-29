import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// A cmux page in Chromium discards through its tab's in-place discard. Chromium
/// reloads the discarded entry when the page shows, so the page host's show and load of the same URL
/// send no reload or navigation of cmux's own; once the entry commits again a load navigates. A fork
/// without the export answers false so the page host closes the page. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFPageChromiumPageDiscardTests {
    @Test func theShowAndLoadAfterADiscardLeaveTheRestoreToChromium() throws {
        let rig = try PageDiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let page = try rig.page()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))

        #expect(page.discard())
        PageDiscardSpy.loads = []
        page.setVisible(true)
        page.load(route)
        #expect(PageDiscardSpy.reloads.isEmpty, "cmux reloaded on top of Chromium's restore on show")
        #expect(PageDiscardSpy.loads.isEmpty, "the discarded entry was replaced by a new navigation")

        // Chromium's restore commits the entry: the page is live again.
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))
        page.load(route)
        #expect(PageDiscardSpy.loads == [route.absoluteString], "a load into a live page is a navigation")
        #expect(PageDiscardSpy.reloads.isEmpty)
    }

    @Test func aReloadAfterADiscardEndsIt() throws {
        let rig = try PageDiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let page = try rig.page()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))

        #expect(page.discard())
        PageDiscardSpy.loads = []
        page.reload()
        page.load(route)
        #expect(PageDiscardSpy.reloads == [7])
        #expect(PageDiscardSpy.loads == [route.absoluteString])
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

    /// The crash watch is a service observation (the page host reloads a crashed page,
    /// shown or not). A renderer already gone when the host listens is one `.crashed`, sent by the posted
    /// check after the listen, never inside it; a later exit after a reload is one more.
    @Test func aCrashPresentAtTheListenIsOneEventAfterAFrame() throws {
        let rig = try PageDiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let frames = PageFrameRig()
        let page = try rig.page(mainWork: frames.work)
        page.tab.rendererTerminated(BrowserProcessExit(reason: .crashed))
        var crashes = 0
        page.onEvent = { event in if event == .crashed { crashes += 1 } }
        #expect(crashes == 0, "the crash was sent inside the listen")
        frames.frame()
        #expect(crashes == 1, "the crash present at the listen was not sent once")
        frames.frame()
        #expect(crashes == 1, "the same crash was sent again")
        page.onEvent = nil
    }

    @MainActor final class PageDiscardRig {
        let runtime: CEFRuntime
        let root: URL

        init(exportsDiscard: Bool) throws {
            PageDiscardSpy.reset(exportsDiscard: exportsDiscard)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try PageDiscardSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A page whose tab's browser 7 exists (AFTER_CREATED); its crash watch flushes on `mainWork`.
        func page(mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())) throws -> CEFPageChromiumPage {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return CEFPageChromiumPage(tab: tab, pageID: "cmux.markdown", mainWork: mainWork)
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
