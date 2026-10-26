import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// p14-energy-124: a tab's main-frame renderer pid comes from the fork's `cmux_cef_browser_renderer_pid`
/// through `cmux_shim_renderer_pid`, for the browser the tab holds. The shim answers 0 on a fork
/// without the call and while there is no renderer; the tab then reports none. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFTabRendererPIDTests {
    @Test func theForksPidIsTheTabsRenderer() throws {
        let rig = try RendererPIDRig(answer: 4242)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        #expect(tab.rendererPID == 4242)
        #expect(RendererPIDSpy.asked == [7], "the shim is asked for the tab's own browser")
    }

    @Test func noRendererIsNoPid() throws {
        let rig = try RendererPIDRig(answer: 0)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        #expect(tab.rendererPID == nil)
    }

    @Test func aTabWithNoBrowserAsksNothing() throws {
        let rig = try RendererPIDRig(answer: 4242)
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: rig.runtime)
        let unborn = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        #expect(unborn.rendererPID == nil)
        #expect(RendererPIDSpy.asked.isEmpty)
    }

    /// The tab publishes its renderers at once and again when a load phase changes or its renderer ends
    /// (a navigation can move it to another renderer); a commit in the same load asks the shim nothing.
    /// Once its id names another page it stops publishing.
    @Test func aLoadPhaseChangeOrARendererExitRepublishesTheTabsRenderers() throws {
        let rig = try RendererPIDRig(answer: 4242)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let directory = TabRendererDirectory()
        var current = true
        tab.publishRenderers(as: "t1", into: directory) { _ in current }
        #expect(directory.snapshot() == [ProcessUsage.TabRenderers(tab: "t1", title: "", pid: 4242, rendererClients: [])])

        RendererPIDSpy.answer = 5151
        rig.runtime.handle(.loadStart(browser: 7, url: "https://example.com/", fromPost: false))
        #expect(directory.snapshot().first?.pid == 5151, "a navigation's new renderer is published")
        let asked = RendererPIDSpy.asked.count
        rig.runtime.handle(.loadStart(browser: 7, url: "https://example.com/a", fromPost: false))
        #expect(RendererPIDSpy.asked.count == asked, "a commit in the same load is no new phase")

        RendererPIDSpy.answer = 0
        rig.runtime.handle(.renderTerminated(browser: 7, status: 2, code: 11, text: "crashed"))
        #expect(directory.snapshot().first?.pid == nil, "the ended renderer is no longer the tab's")

        current = false
        RendererPIDSpy.answer = 6161
        rig.runtime.handle(.loadStart(browser: 7, url: "https://example.com/b", fromPost: false))
        #expect(directory.snapshot().first?.pid == nil, "a page its id no longer names publishes nothing")
    }

    // MARK: Rig

    @MainActor final class RendererPIDRig {
        let runtime: CEFRuntime
        let root: URL

        init(answer: Int32) throws {
            RendererPIDSpy.reset(answer: answer)
            root = FileManager.default.temporaryDirectory.appending(path: "cef-tab-renderer-pid-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(RendererPIDSpy.symbol), storage: CEFProfileStorage(root: root))
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
            RendererPIDSpy.asked = []
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// A fake fork behind the shim: `cmux_shim_renderer_pid` answers ``answer`` and records the browser
/// asked; every other function does nothing.
private nonisolated enum RendererPIDSpy {
    nonisolated(unsafe) static var answer: Int32 = 0
    nonisolated(unsafe) static var asked: [Int32] = []

    static func reset(answer pid: Int32) {
        answer = pid
        asked = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let rendererPID: @convention(c) (Int32) -> Int32 = { browser in RendererPIDSpy.asked.append(browser); return RendererPIDSpy.answer }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_renderer_pid": unsafeBitCast(rendererPID, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
