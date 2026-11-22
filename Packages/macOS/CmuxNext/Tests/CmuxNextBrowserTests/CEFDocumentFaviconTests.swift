import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42435: a browser tab showed the globe instead of its site's icon
/// (Spotify). Chromium tells a document's favicon (OnFaviconURLChange) only while that document parses its icon
/// links, and drops the report of a document that is not yet the tab's page. A page restored from the back/forward
/// cache, or activated from a prerender (a search result Google prerendered), parsed them before it became the tab's
/// page, so its commit brings no favicon report; the commit on another host had already cleared the old site's
/// icon, and the tab kept the globe. Chrome reads such a document's icon list at the commit (its favicon driver's
/// back/forward-cache and prerender case); cmux reads it from the document when its load ends with none reported.
@MainActor @Suite(.serialized) struct CEFDocumentFaviconTests {
    static let browser: Int32 = 23

    /// A document restored on another host with no favicon report ends with the icon its own links name.
    @Test func aDocumentWhoseFaviconWasNeverReportedGetsTheIconItsLinksName() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.load("https://a.example/", favicon: "https://a.example/a.png")
        #expect(tab.state.faviconURL?.absoluteString == "https://a.example/a.png")
        #expect(FaviconSpy.reads.isEmpty, "a reported favicon needs no read of the document")

        // Back to a page on another host, out of the back/forward cache: a commit, a load end, no favicon report.
        rig.load("https://open.example/artist/1", favicon: nil)
        await rig.until { !FaviconSpy.reads.isEmpty }
        let read = try #require(FaviconSpy.reads.first, "the document's icon list is read when no favicon was reported")
        #expect(read.world == "cmux", "read in cmux's isolated world: the page cannot patch what it answers")
        rig.runtime.handle(.evaluateResult(token: read.token, status: 1, value: #""https://cdn.example/favicon32.png""#))
        await rig.until { tab.state.faviconURL != nil }
        #expect(tab.state.faviconURL?.absoluteString == "https://cdn.example/favicon32.png",
                "the tab shows the restored document's own icon, not the globe")
    }

    /// A document with no icon link gets the site's `/favicon.ico`, as Chromium's default candidate is.
    @Test func aDocumentWithNoIconLinkGetsTheSitesDefaultFavicon() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.load("https://b.example/page?x=1", favicon: nil)
        await rig.until { !FaviconSpy.reads.isEmpty }
        let read = try #require(FaviconSpy.reads.first)
        rig.runtime.handle(.evaluateResult(token: read.token, status: 1, value: #""""#))
        await rig.until { tab.state.faviconURL != nil }
        #expect(tab.state.faviconURL?.absoluteString == "https://b.example/favicon.ico")
    }

    /// The read's answer is for its own document: one that committed meanwhile, or that Chromium reported a favicon
    /// for meanwhile, keeps its own.
    @Test func aLateReadNeverReplacesAReportedOrNewerDocumentsIcon() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.load("https://c.example/", favicon: nil)
        await rig.until { !FaviconSpy.reads.isEmpty }
        let stale = try #require(FaviconSpy.reads.first)
        let staleRead = try #require(tab.documentFaviconRead, "the read runs as the tab's own task")
        rig.runtime.handle(.favicon(browser: Self.browser, url: "https://c.example/reported.png"))
        rig.runtime.handle(.evaluateResult(token: stale.token, status: 1, value: #""https://c.example/read.png""#))
        await staleRead.value // the late answer has been handled, not merely not yet arrived
        #expect(tab.state.faviconURL?.absoluteString == "https://c.example/reported.png")

        rig.load("https://d.example/", favicon: nil)
        await rig.until { FaviconSpy.reads.count == 2 }
        let first = try #require(FaviconSpy.reads.last)
        let firstRead = try #require(tab.documentFaviconRead)
        rig.load("https://e.example/", favicon: "https://e.example/e.png")
        rig.runtime.handle(.evaluateResult(token: first.token, status: 1, value: #""https://d.example/d.png""#))
        await firstRead.value
        #expect(tab.state.faviconURL?.absoluteString == "https://e.example/e.png")
    }

    /// Not a web page (an error page, a data or file address): nothing to read.
    @Test func aPageThatIsNotOnTheWebIsNotRead() async throws {
        let rig = try Rig()
        defer { rig.close() }
        _ = try rig.attachedTab()
        rig.load("file:///tmp/page.html", favicon: nil)
        await rig.settle()
        #expect(FaviconSpy.reads.isEmpty)
    }

    // MARK: Rig

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            FaviconSpy.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-document-favicon-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try FaviconSpy.library(), storage: CEFProfileStorage(root: root))
        }

        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: CEFDocumentFaviconTests.browser, request: request, window: 1))
            try #require(tab.browserID == CEFDocumentFaviconTests.browser)
            return tab
        }

        /// One navigation as CEF reports it: loading, the commit (OnLoadStart), the favicon report when the document
        /// parsed its links while it was the tab's page, the load end, loading stopped.
        func load(_ url: String, favicon: String?) {
            let browser = CEFDocumentFaviconTests.browser
            runtime.handle(.loadingState(browser: browser, loading: true, canGoBack: false, canGoForward: false))
            runtime.handle(.loadStart(browser: browser, url: url, fromPost: false))
            if let favicon { runtime.handle(.favicon(browser: browser, url: favicon)) }
            runtime.handle(.loadEnd(browser: browser, httpStatus: 200))
            runtime.handle(.loadingState(browser: browser, loading: false, canGoBack: true, canGoForward: false))
        }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }

        func until(_ condition: () -> Bool) async {
            for _ in 0..<500 where !condition() { await Task.yield() }
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs: it lives to the end of the test process (`CEFFirstPaintBaseTests.Rig`).
            Self.kept.append(self)
        }

        static var kept: [Rig] = []
    }
}

/// The fake shim (fork API 29: the tab's own scripts go through the renderer path): which favicon reads it was asked.
private nonisolated enum FaviconSpy {
    struct Read { let token: Int32; let world: String }
    nonisolated(unsafe) static var reads: [Read] = []

    static func reset() { reads = [] }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let evaluate: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = { _, token, world, script, _ in
            if script.map({ String(cString: $0) }) == CEFTab.documentFaviconScript {
                FaviconSpy.reads.append(Read(token: token, world: world.map { String(cString: $0) } ?? ""))
            }
            return 1
        }
        let one: @convention(c) () -> Int32 = { 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_evaluate": unsafeBitCast(evaluate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_add_document_script", "cmux_shim_add_page_channel", "cmux_shim_tab_set_frozen",
                 "cmux_shim_tab_send_click", "cmux_shim_tab_set_color_scheme":
                unsafeBitCast(one, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
