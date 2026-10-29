import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// p07-memory-101: a hidden Chromium tab empties its back-forward cache through the shim's
/// `cmux_shim_tab_flush_back_forward_cache` (the fork's `BackForwardCache::Flush`,
/// content/public/browser/back_forward_cache.h): one call for the tab's browser, none for a tab the content lifecycle
/// shows, one with no browser yet, or a closed one. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFTabFreezeBackForwardCacheTests {
    @Test func aHiddenTabSendsOneFlushForItsBrowser() throws {
        let rig = try FlushRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        #expect(tab.flushBackForwardCache())
        #expect(FlushSpy.flushed == [7])
    }

    @Test func aShownTabIsNeverFlushed() throws {
        let rig = try FlushRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(true)
        #expect(!tab.flushBackForwardCache())
        #expect(FlushSpy.flushed.isEmpty)
    }

    @Test func aTabWithNoBrowserOrClosedSendsNothing() throws {
        let rig = try FlushRig()
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: rig.runtime)
        let unborn = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        unborn.setContentVisible(false)
        #expect(!unborn.flushBackForwardCache())
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        tab.close()
        #expect(!tab.flushBackForwardCache())
        #expect(FlushSpy.flushed.isEmpty)
    }

    /// The fork's answer is not read (a post to the Chromium Host in host mode): a fork without the call still
    /// counts as asked, and Chromium does nothing.
    @Test func theForksAnswerIsNotRead() throws {
        let rig = try FlushRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        FlushSpy.answer = 0
        #expect(tab.flushBackForwardCache())
        #expect(FlushSpy.flushed == [7])
    }

    // MARK: Rig

    @MainActor final class FlushRig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            FlushSpy.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-tab-bfcache-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(FlushSpy.symbol), storage: CEFProfileStorage(root: root))
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

/// The shim's flush calls, recorded; every other function does nothing.
private nonisolated enum FlushSpy {
    nonisolated(unsafe) static var answer: Int32 = 1
    nonisolated(unsafe) static var flushed: [Int32] = []

    static func reset() {
        answer = 1
        flushed = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let flush: @convention(c) (Int32) -> Int32 = { browser in FlushSpy.flushed.append(browser); return FlushSpy.answer }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_flush_back_forward_cache": unsafeBitCast(flush, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
