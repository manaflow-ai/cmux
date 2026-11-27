import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// u3600 (Lawrence 2026-10-19): "pane-tab mute must be a real toggle". The speaker and Mute Tab
/// only set each media element's `muted` from a script, so Web Audio, a frame in another process
/// and a new document's first moments kept playing with the tab shown muted. Mute Tab now mutes
/// the page in the engine, as Chrome's Mute site, and Unmute takes that back.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabAudioMuteEngineTests {
    /// WebKit: the tab's mute is WebKit's page mute, on and off as many times as it is pressed.
    @Test func aWebKitTabMutesThePageInWebKit() throws {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        try #require(page.isPageAudioMuted == false, "this WebKit has no page mute")
        for muted in [true, false, true, false] {
            page.setAudioMuted(muted)
            #expect(page.state.isAudioMuted == muted)
            #expect(page.isPageAudioMuted == muted, "WebKit's page mute is \(String(describing: page.isPageAudioMuted)) after a mute of \(muted)")
        }
    }

    /// Chromium: the tab's mute is the browser's (`cmux_shim_set_audio_muted`), and a browser made
    /// after the mute (a page woken or restarted) is muted when it attaches.
    @Test func aChromiumTabMutesItsBrowserAndABrowserMadeLater() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-mute-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        MuteSpyShim.calls = []
        let runtime = CEFRuntime(shim: try MuteSpyShim.library(), storage: CEFProfileStorage(root: root))
        MuteSpyShim.runtimes.append(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.add(tab)

        tab.setAudioMuted(true)
        #expect(MuteSpyShim.calls.isEmpty, "a tab with no browser yet muted one: \(MuteSpyShim.calls)")
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 5, request: request, window: 1))
        #expect(MuteSpyShim.calls == [MuteSpyShim.Call(browser: 5, muted: 1)], "the new browser was not muted: \(MuteSpyShim.calls)")

        tab.setAudioMuted(false)
        tab.setAudioMuted(true)
        #expect(MuteSpyShim.calls.dropFirst() == [MuteSpyShim.Call(browser: 5, muted: 0), MuteSpyShim.Call(browser: 5, muted: 1)])
    }
}

/// Stand-in shim: `cmux_shim_set_audio_muted` records each call, `cmux_shim_create_window` reports
/// the browser started; every other function does nothing.
private nonisolated enum MuteSpyShim {
    struct Call: Equatable { let browser: Int32; let muted: Int32 }
    nonisolated(unsafe) static var calls: [Call] = [] // test-only, main thread (the suite is serialized)
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let setMuted: @convention(c) (Int32, Int32) -> Void = { browser, muted in MuteSpyShim.calls.append(Call(browser: browser, muted: muted)) }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_audio_muted": unsafeBitCast(setMuted, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
