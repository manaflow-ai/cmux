import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// P0 #1 (2026-10-28): optimized builds crashed in Chromium (SIGSEGV at 0 in
/// `RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived`) when a DevTools `Page.captureScreenshot` was in flight on a
/// page whose view went away: a hidden page's surface copy fails and retries, and the quit (19 of 21 reports) or a
/// discard closed its renderer meanwhile. cmux asks Chromium for a page's picture only while its browser lives and
/// the engine is not stopping, and for its own pictures (thumbnails) only while the page shows; a person's or an
/// agent's screenshot of a hidden page is still taken. A picture asked for and not answered when the browser closes
/// ends with no picture, and its late answer is dropped.
@MainActor @Suite(.serialized) struct CEFPageCaptureLifetimeTests {
    @Test func aShownPageIsPictured() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        // The answer never comes: the send is checked, then the close ends the wait with no picture.
        let picture = Task { @MainActor in try? await tab.snapshot() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while CaptureSpy.methods.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(CaptureSpy.methods == ["Page.captureScreenshot"], "a shown page was not pictured")
        rig.runtime.handle(.beforeClose(browser: 7))
        #expect(await picture.value == nil, "a closed page's picture came back")
    }

    @Test func aHiddenPageGetsNoThumbnail() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        await #expect(throws: BrowserTabError.snapshotUnavailable) { try await tab.thumbnail() }
        #expect(!CaptureSpy.methods.contains("Page.captureScreenshot"), "a hidden page was pictured: \(CaptureSpy.methods)")
    }

    /// `browser.page.screenshot` of a background tab: DevTools keeps the hidden page drawing for it.
    @Test func aScreenshotOfAHiddenPageIsStillTaken() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        let picture = Task { @MainActor in try? await tab.snapshot() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while CaptureSpy.methods.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(CaptureSpy.methods == ["Page.captureScreenshot"], "a screenshot of a hidden page was refused")
        rig.runtime.handle(.beforeClose(browser: 7))
        #expect(await picture.value == nil)
    }

    @Test func noPageIsPicturedOnceTheEngineStops() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        var stopping = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        stopping.begin()
        rig.runtime.shutdownSequence = stopping
        await #expect(throws: BrowserTabError.snapshotUnavailable) { try await tab.snapshot() }
        await #expect(throws: BrowserTabError.snapshotUnavailable) { try await tab.thumbnail() }
        #expect(!CaptureSpy.methods.contains("Page.captureScreenshot"), "a page was pictured after quit began: \(CaptureSpy.methods)")
    }

    /// A screenshot of a hidden page still waiting when quit begins ends then with `closed` (no wait for the quit's
    /// browser closes or its timeout): the engine is stopping and will never answer it.
    @Test func aScreenshotWaitingWhenQuitBeginsEndsAtOnce() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.setContentVisible(false)
        let picture = Task { @MainActor () -> (any Error)? in
            do { _ = try await tab.snapshot(); return nil } catch { return error }
        }
        var deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while CaptureSpy.methods.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(CaptureSpy.methods == ["Page.captureScreenshot"])
        // The browser never closes (the spy reports no close): the quit waits out its timeout.
        let quit = Task { await rig.runtime.shutdown(timeout: .seconds(2)) }
        deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let ended = Flag()
        let watcher = Task { _ = await picture.value; ended.isSet = true }
        while !ended.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ended.isSet, "the screenshot still waited a second after quit began")
        #expect(await picture.value as? BrowserTabError == .closed)
        watcher.cancel()
        await quit.value
    }

    @Test func aClosedPageIsNeverPictured() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.beforeClose(browser: 7))
        await #expect(throws: (any Error).self) { try await tab.snapshot() }
        #expect(!CaptureSpy.methods.contains("Page.captureScreenshot"))
    }

    // MARK: Rig

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            CaptureSpy.methods = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-capture-lifetime-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CaptureSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A shown tab whose browser 7 exists (AFTER_CREATED).
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

/// Set by a task the test watches (all on the main actor).
@MainActor private final class Flag {
    var isSet = false
}

/// The DevTools methods a CEFTab sends; each gets a message id and no answer.
private nonisolated enum CaptureSpy {
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var nextMessage: Int32 = 100

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 30 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, _ in
            CaptureSpy.methods.append(method.map { String(cString: $0) } ?? "")
            CaptureSpy.nextMessage += 1
            return CaptureSpy.nextMessage
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
