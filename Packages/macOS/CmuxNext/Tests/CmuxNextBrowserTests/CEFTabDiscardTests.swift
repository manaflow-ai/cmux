import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A hidden cmux page in Chromium is discarded in place, as Chrome's Memory Saver does
/// (`WebContents::Discard`, content/public/browser/web_contents.h), through the fork's optional
/// `cmux_shim_tab_discard`. A fork without the export, or the Chromium Host (whose
/// answer is a later reply), discards nothing, so the page host closes the page instead. After a
/// discard Chromium reloads the entry when the page shows (`NavigationControllerImpl::LoadIfNecessary`),
/// so cmux sends nothing for a load of that entry's URL. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFTabDiscardTests {
    @Test func theDiscardExportIsOptional() throws {
        DiscardSpy.reset(exportsDiscard: false)
        let library = try DiscardSpy.library()
        #expect(library.tabDiscard == nil)
        DiscardSpy.reset(exportsDiscard: true)
        #expect(try DiscardSpy.library().tabDiscard != nil)
    }

    /// In host mode the remote shim's return only says the op was sent, so no discard binds there:
    /// the page host closes the page instead of taking "sent" for Chromium's answer.
    @Test func hostModeBindsNoDiscard() throws {
        DiscardSpy.reset(exportsDiscard: true)
        let library = try CEFShimLibrary.resolving(DiscardSpy.symbol, hostExports: ["cmux_shim_tab_discard"])
        #expect(library.tabDiscard == nil)
    }

    @Test func aForkWithoutTheExportDiscardsNothing() throws {
        let rig = try DiscardRig(exportsDiscard: false)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        #expect(!tab.discard())
        #expect(DiscardSpy.discarded.isEmpty)
    }

    @Test func aDiscardGoesToTheTabsBrowserAndReportsTheForksAnswer() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        DiscardSpy.discardAnswer = 0
        #expect(!tab.discard(), "a page Chromium still counts visible is refused")
        DiscardSpy.discardAnswer = 1
        #expect(tab.discard())
        #expect(DiscardSpy.discarded == [7, 7])
        #expect(tab.browserID == 7, "the tab keeps its browser")
    }

    @Test func aTabWithNoBrowserOrClosedDiscardsNothing() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: rig.runtime)
        let unborn = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        #expect(!unborn.discard())
        let tab = try rig.attachedTab()
        tab.close()
        #expect(!tab.discard())
        #expect(DiscardSpy.discarded.isEmpty)
    }

    /// The discarded entry comes back by Chromium's own restore on show: a load of its URL, after the
    /// page shows, sends neither a reload nor a navigation; another URL is a new navigation.
    @Test func aLoadOfTheDiscardedEntrySendsNothing() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/doc"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))
        #expect(tab.discard())
        DiscardSpy.loads = []
        DiscardSpy.reloads = []

        tab.setContentVisible(true)
        tab.loadRestoringDiscard(route)
        #expect(DiscardSpy.reloads.isEmpty, "cmux reloaded on top of Chromium's restore")
        #expect(DiscardSpy.loads.isEmpty, "the discarded entry was replaced by a new navigation")
        #expect(tab.browserID == 7)

        let other = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/other"))
        tab.loadRestoringDiscard(other)
        #expect(DiscardSpy.loads == [other.absoluteString])
        #expect(DiscardSpy.reloads.isEmpty)
    }

    /// A route a same-document navigation set (`.address`, no OnLoadStart) is the entry's URL.
    @Test func theEntryURLFollowsASameDocumentRouteChange() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let first = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/a"))
        let moved = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/b"))
        rig.runtime.handle(.loadStart(browser: 7, url: first.absoluteString, fromPost: false))
        rig.runtime.handle(.address(browser: 7, url: moved.absoluteString))
        #expect(tab.discard())
        DiscardSpy.loads = []
        DiscardSpy.reloads = []

        tab.loadRestoringDiscard(moved)
        #expect(DiscardSpy.loads.isEmpty)
        #expect(DiscardSpy.reloads.isEmpty)
    }

    /// Once the entry commits again (Chromium's restore on show), the tab is live: a later load of the
    /// same URL is an ordinary navigation, never the discard path.
    @Test func aCommitEndsTheDiscard() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/doc"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))
        #expect(tab.discard())
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))
        DiscardSpy.loads = []

        tab.loadRestoringDiscard(route)
        #expect(DiscardSpy.loads == [route.absoluteString])
    }

    /// A refused discard leaves the tab live, so a load is a navigation.
    @Test func aRefusedDiscardLeavesTheTabLive() throws {
        let rig = try DiscardRig(exportsDiscard: true)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let route = try #require(URL(string: "cmux-page://cmux.markdown/index.html#/doc"))
        rig.runtime.handle(.loadStart(browser: 7, url: route.absoluteString, fromPost: false))
        DiscardSpy.discardAnswer = 0
        #expect(!tab.discard())
        DiscardSpy.loads = []

        tab.loadRestoringDiscard(route)
        #expect(DiscardSpy.loads == [route.absoluteString])
    }

    // MARK: Rig

    @MainActor final class DiscardRig {
        let runtime: CEFRuntime
        let root: URL

        init(exportsDiscard: Bool) throws {
            DiscardSpy.reset(exportsDiscard: exportsDiscard)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-tab-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try DiscardSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser 7 exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
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

/// The shim's discard, load and reload calls, recorded; every other function does nothing.
private nonisolated enum DiscardSpy {
    nonisolated(unsafe) static var exportsDiscard = true
    nonisolated(unsafe) static var discardAnswer: Int32 = 1
    nonisolated(unsafe) static var discarded: [Int32] = []
    nonisolated(unsafe) static var loads: [String] = []
    nonisolated(unsafe) static var reloads: [Int32] = []

    static func reset(exportsDiscard exports: Bool) {
        exportsDiscard = exports
        discardAnswer = 1
        discarded = []
        loads = []
        reloads = []
    }

    static func library() throws -> CEFShimLibrary {
        try CEFShimLibrary.resolving(symbol)
    }

    /// The spy's function named `name`; the discard export only while ``exportsDiscard``.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let discard: @convention(c) (Int32) -> Int32 = { browser in DiscardSpy.discarded.append(browser); return DiscardSpy.discardAnswer }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in DiscardSpy.loads.append(url.map { String(cString: $0) } ?? "") }
        let reload: @convention(c) (Int32) -> Void = { browser in DiscardSpy.reloads.append(browser) }
        let nothing: @convention(c) () -> Int = { 0 }
        if name == "cmux_shim_tab_discard" {
            return exportsDiscard ? unsafeBitCast(discard, to: UnsafeMutableRawPointer.self) : nil
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
