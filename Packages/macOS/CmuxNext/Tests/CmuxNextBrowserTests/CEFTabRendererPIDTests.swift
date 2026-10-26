import AppKit
@testable import CmuxNextBrowser
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
