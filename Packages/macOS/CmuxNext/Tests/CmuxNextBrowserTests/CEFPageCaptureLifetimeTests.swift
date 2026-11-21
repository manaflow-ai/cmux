import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Dogfood P0 #1 (2026-10-28, 57 of 65 crash reports; handoff/cef-snapshot-crash-result.md): optimized builds crashed
/// in Chromium (SIGSEGV at 0 in `RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived`) when a DevTools
/// `Page.captureScreenshot` was in flight on a page whose view went away: a hidden page's surface copy fails and
/// retries, and the quit (19 of 21 reports) or a discard closed its renderer meanwhile. cmux asks Chromium for a
/// page's picture only while its browser lives and the engine is not stopping, and for its own pictures (thumbnails)
/// only while the page shows; a person's or an agent's screenshot of a hidden page is still taken. A picture asked
/// for and not answered when the browser closes or quit begins ends then with no picture, and its late answer is
/// dropped. feat's CEF pin (cef-154.0.34-cmux.38) lacks the fork's `cmux_snapshot_view_gone` patch, so these app
/// rules are the only guard there.
@MainActor @Suite(.serialized) struct CEFPageCaptureLifetimeTests {
    @Test func aShownPageIsPictured() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        // The answer never comes: the send is checked, then the close ends the wait with no picture.
        let picture = Task { @MainActor in try? await tab.snapshot() }
        await rig.until { !CaptureSpy.screenshots.isEmpty }
        #expect(CaptureSpy.screenshots.count == 1, "a shown page was not pictured: \(CaptureSpy.methods)")
        rig.runtime.handle(.beforeClose(browser: Rig.browser))
        #expect(await picture.value == nil, "a closed page's picture came back")
    }

    @Test func aHiddenPageGetsNoThumbnail() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        tab.setContentVisible(false)
        let thumbnail = Task { @MainActor () -> (any Error)? in
            do { _ = try await tab.thumbnail(); return nil } catch { return error }
        }
        await rig.until { !CaptureSpy.screenshots.isEmpty }
        #expect(CaptureSpy.screenshots.isEmpty, "a hidden page was pictured: \(CaptureSpy.methods)")
        rig.runtime.handle(.beforeClose(browser: Rig.browser)) // ends a wait the red build started
        #expect(await thumbnail.value as? BrowserTabError == .snapshotUnavailable)
    }

    /// `browser.page.screenshot` of a background tab: DevTools keeps the hidden page drawing for it.
    @Test func aScreenshotOfAHiddenPageIsStillTaken() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        tab.setContentVisible(false)
        let picture = Task { @MainActor in try? await tab.snapshot() }
        await rig.until { !CaptureSpy.screenshots.isEmpty }
        #expect(CaptureSpy.screenshots.count == 1, "a screenshot of a hidden page was refused: \(CaptureSpy.methods)")
        rig.runtime.handle(.beforeClose(browser: Rig.browser))
        #expect(await picture.value == nil)
    }

    @Test func noPageIsPicturedOnceTheEngineStops() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        var stopping = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        stopping.begin()
        rig.runtime.shutdownSequence = stopping
        let pictures = Task { @MainActor () -> [(any Error)?] in
            var errors: [(any Error)?] = []
            do { _ = try await tab.snapshot(); errors.append(nil) } catch { errors.append(error) }
            do { _ = try await tab.thumbnail(); errors.append(nil) } catch { errors.append(error) }
            return errors
        }
        await rig.until { !CaptureSpy.screenshots.isEmpty }
        #expect(CaptureSpy.screenshots.isEmpty, "a page was pictured after quit began: \(CaptureSpy.methods)")
        rig.runtime.shutdownSequence = nil
        rig.runtime.handle(.beforeClose(browser: Rig.browser)) // ends a wait the red build started
        #expect(await pictures.value.map { $0 as? BrowserTabError } == [.snapshotUnavailable, .snapshotUnavailable])
    }

    /// A screenshot of a hidden page still waiting when quit begins ends then with `closed` (no wait for the quit's
    /// browser closes or its timeout): the engine is stopping and will never answer it.
    @Test func aScreenshotWaitingWhenQuitBeginsEndsAtOnce() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        tab.setContentVisible(false)
        let picture = Task { @MainActor () -> (any Error)? in
            do { _ = try await tab.snapshot(); return nil } catch { return error }
        }
        await rig.until { !CaptureSpy.screenshots.isEmpty }
        try #require(CaptureSpy.screenshots.count == 1)
        // The browser never closes (the spy reports no close): the quit waits out its timeout.
        let quit = Task { await rig.runtime.shutdown(timeout: .seconds(3)) }
        let ended = Flag()
        let watcher = Task { _ = await picture.value; ended.isSet = true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !ended.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ended.isSet, "the screenshot still waited a second after quit began")
        #expect(await picture.value as? BrowserTabError == .closed)
        watcher.cancel()
        await quit.value
    }

    /// A picture asked for while another call of the browser waits (the queued branch of `startDevTools`) is
    /// checked again at its turn: the page hid meanwhile, so nothing is sent, and the line empties.
    @Test func aQueuedThumbnailOfAPageThatHidMeanwhileIsRefusedAtItsTurn() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let order = rig.runtime.devToolsOrder
        // The tab's own set-up calls (Page.enable, Emulation.setEmulatedMedia) go first: this ticket must head the line.
        await rig.until { order.isIdle(Rig.browser) }
        try #require(order.isIdle(Rig.browser), "the tab's set-up calls never left the line")
        let ticket = order.take(Rig.browser) // a call that still waits to send
        CaptureSpy.methods = []
        let request = tab.beginThumbnail()
        let thumbnail = Task { @MainActor () -> (any Error)? in
            do { _ = try await request.image(); return nil } catch { return error }
        }
        tab.setContentVisible(false)
        order.leave(ticket, of: Rig.browser)
        #expect(await thumbnail.value as? BrowserTabError == .snapshotUnavailable)
        #expect(CaptureSpy.screenshots.isEmpty, "a page hidden before its turn was pictured: \(CaptureSpy.methods)")
        // Calls the tab made meanwhile went behind the ticket; each leaves in its own later turn, so the line empties
        // only if the refused picture left its place.
        await rig.until { order.isIdle(Rig.browser) }
        #expect(order.isIdle(Rig.browser), "the refused picture kept its place in the line (\(order.waiting(Rig.browser)) waiting)")
    }

    /// A picture asked for in one turn and awaited in a later one (the leave picture) keeps an answer that comes
    /// in between: it was dropped, and the wait ran into its timeout.
    @Test func anAnswerThatComesBeforeTheWaitIsKept() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.until { rig.runtime.devToolsOrder.isIdle(Rig.browser) }
        CaptureSpy.methods = []
        let request = tab.beginThumbnail()
        try #require(CaptureSpy.screenshots.count == 1, "the picture was not asked for in the caller's turn")
        let answer = try CEFDevToolsParamsOffMainTests.screenshotAnswer(width: 8, height: 8)
        rig.runtime.handle(.devToolsResult(browser: Rig.browser, messageID: CaptureSpy.nextMessage, success: true, json: answer))
        let started = ContinuousClock.now
        let image = try await request.image()
        #expect(image.width == 8)
        #expect(started.duration(to: .now) < .seconds(1), "the answer that came first was dropped")
    }

    @Test func aClosedPageIsNeverPictured() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        CaptureSpy.methods = []
        rig.runtime.handle(.beforeClose(browser: Rig.browser))
        await #expect(throws: (any Error).self) { try await tab.snapshot() }
        #expect(CaptureSpy.screenshots.isEmpty)
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 7
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            CaptureSpy.methods = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-capture-lifetime-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CaptureSpy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A shown tab whose browser exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            return tab
        }

        /// Yields the main actor until `condition` holds or 2 s pass (a refused picture sends nothing, so the
        /// tests that expect no send wait out the 2 s).
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
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

/// The DevTools methods a CEFTab sends; each gets a message id and no answer. An attached tab also sends its own
/// set-up calls (Page.enable, Emulation.setEmulatedMedia, in later turns), so the tests count only the screenshots.
private nonisolated enum CaptureSpy {
    nonisolated(unsafe) static var methods: [String] = []
    /// The `Page.captureScreenshot` calls among ``methods``.
    static var screenshots: [String] { methods.filter { $0 == "Page.captureScreenshot" } }
    nonisolated(unsafe) static var nextMessage: Int32 = 100

    static func library() throws -> CEFShimLibrary {
        // feat's pinned fork API (cef-154.0.34-cmux.38).
        let version: @convention(c) () -> Int32 = { 24 }
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
