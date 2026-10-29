import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextFocusUI
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Task 028 of plans/cmux-next/chrome-parity/p01-process.md: the App's users of CEF types work with
/// both backends. Chromium's page is a child window of the cmux window only in process; in host mode
/// it is the pane's `ChromiumHostPageView`, a view like any other, so page-window code (focus through
/// the page window, the child-page geometry invariant, `debug.cef`'s child windows) has nothing to do
/// there, while a Chromium page still takes the keys as a Chromium page.
@MainActor @Suite(.serialized) struct ChromiumBackendAppTests {
    @Test(arguments: [false, true])
    func aChromiumPageIsAChildWindowOnlyInProcess(hostMode: Bool) throws {
        let rig = try Rig(hostMode: hostMode)
        defer { rig.close() }
        let content = TabContent.browser(BrowserEntry(tab: rig.tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil))

        #expect(rig.tab.presentation == (hostMode ? .inView : .childWindow))
        #expect(content.chromiumTab === rig.tab, "a Chromium tab takes the keys as a Chromium page in either backend")
        if hostMode {
            #expect(content.childWindowTab == nil, "host mode has no page window")
        } else {
            #expect(content.childWindowTab === rig.tab)
        }
    }

    @Test func aWebKitTabIsNoChromiumTab() {
        let tab = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let content = TabContent.browser(BrowserEntry(tab: tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil))
        #expect(content.chromiumTab == nil)
        #expect(content.childWindowTab == nil)
    }

    @Test func childPageGeometryChecksPageWindowsOnlyInProcess() {
        #expect(ChildPageGeometry.hasPageWindows(.inProcess))
        #expect(!ChildPageGeometry.hasPageWindows(.host))
    }

    /// Host mode: a Chromium page that takes focus (Cmd-Opt-arrow, a tab select, Escape from the
    /// omnibar) takes the keys from the terminal that had them, and is embedder-active; focus that
    /// moves on to a terminal or an empty pane (`blurChildWindowPage`) makes it inactive again.
    @Test func aHostModeChromiumPageTakesTheKeysAndGivesThemBack() throws {
        let rig = try LiveHostRig()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let terminal = KeyTaker(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(pane)
        window.contentView?.addSubview(terminal)
        rig.host.present(rig.tab, in: pane)
        #expect(window.makeFirstResponder(terminal))
        let pages = ChildPageFocus(keys: AppKitKeyWindows()) { page, focused in (page as? any BrowserTab)?.setFocused(focused) }

        // FocusEffectApplier.focusPage's step for a Chromium page in either backend.
        pages.focus(rig.tab, in: window) { ($0 as? NSView)?.isDescendant(of: rig.tab.contentView) == true }

        #expect(window.firstResponder === window, "the terminal keeps no keys and no caret")
        #expect(EmbedderActiveSpy.calls.map(\.active) == [1])
        #expect(pages.page === rig.tab, "tracked, so focus leaving it blurs it")

        pages.blurPage()

        #expect(EmbedderActiveSpy.calls.map(\.active) == [1, 0])
        #expect(EmbedderActiveSpy.calls.allSatisfy { $0.browser == LiveHostRig.browser })
    }

    /// `debug.cef`: host mode has no pump and no fork tracker in this process, but this process
    /// still counts its hosted page views (`tracker.hosted_pages`).
    @Test func debugCEFReportsHostedPagesInBothBackendsAndThePumpOnlyInProcess() throws {
        var tracker = CEFTrackerStats()
        tracker.hostedPages = 2
        tracker.clipReads = 5
        let pump = CEFPumpStats()

        let hosted = DebugCEF.engineCounters(backend: .host, pump: pump, tracker: tracker)
        #expect(hosted["pump"] == nil)
        let hostedTracker = try #require(hosted["tracker"])
        #expect(hostedTracker["hosted_pages"] == .number(2))
        #expect(hostedTracker["clip_reads"] == nil, "the fork's tracker runs in the Chromium Host")

        let local = DebugCEF.engineCounters(backend: .inProcess, pump: pump, tracker: tracker)
        #expect(local["pump"] != nil)
        let localTracker = try #require(local["tracker"])
        #expect(localTracker["hosted_pages"] == .number(2))
        #expect(localTracker["clip_reads"] == .number(5))
    }

    @Test func theRuntimeServiceReportsTheBackendOfItsSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-backend-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A bundle with no runtime and no pin: the service's source is the only thing read.
        let empty = try #require(Bundle(path: root.path))
        let work = BackgroundWork(label: "test.chromium-backend")
        let local = ChromiumRuntimeService.make(work: work, bundle: empty, environment: [:], applicationSupport: nil)
        #expect(local.backend == .inProcess)
        #expect(local.source.hostSupervisor == nil)
        let hosted = ChromiumRuntimeService.make(work: work, bundle: empty, environment: [:], applicationSupport: nil,
                                                 hostSupervisor: NeverAttachingSupervisor())
        #expect(hosted.backend == .host)
        #expect(hosted.source.hostSupervisor != nil)
    }

    /// A pane with one Chromium tab against a stand-in shim; host mode has a host start that never attaches.
    @MainActor final class Rig {
        let runtime: CEFRuntime
        let tab: CEFTab
        let root: URL

        init(hostMode: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "chromium-backend-app-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(NothingShim.symbol), storage: CEFProfileStorage(root: root))
            if hostMode { runtime.hostStart = CEFHostStart(supervisor: NeverAttachingSupervisor()) }
            // A tab's scheduled work reads the runtime through an unowned reference: it outlives the test.
            _ = Unmanaged.passRetained(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A host-mode pane whose tab has a live browser, against a shim that records embedder-active posts.
    @MainActor final class LiveHostRig {
        static let browser: Int32 = 1
        let host: CEFPaneHost
        let tab: CEFTab

        init() throws {
            EmbedderActiveSpy.reset()
            let root = FileManager.default.temporaryDirectory.appending(path: "chromium-backend-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
            let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(EmbedderActiveSpy.symbol), storage: CEFProfileStorage(root: root))
            let hostStart = CEFHostStart(supervisor: NeverAttachingSupervisor(), clock: ContinuousClock())
            hostStart.mapsClientIDs = true
            runtime.hostStart = hostStart
            // A pane's scheduled work reads the runtime through an unowned reference: it outlives the test.
            _ = Unmanaged.passRetained(runtime)
            host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            #expect(tab.browserID == Self.browser)
            // The host detached the page (its layer hosting reply): its focus is embedder-active.
            tab.hostDetachedPage(browser: Self.browser)
        }
    }

    /// Takes the keyboard the way a terminal surface does.
    final class KeyTaker: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}

/// Stand-in shim for a live host-mode pane: `browser_set_embedder_active` records its calls,
/// `create_window` succeeds, `fork_api_version` reports 30, every other function returns 0.
private nonisolated enum EmbedderActiveSpy {
    nonisolated(unsafe) static var calls: [(browser: Int32, active: Int32)] = []

    static func reset() { calls = [] }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { 0 }
        let embedderActive: @convention(c) (Int32, Int32) -> Int32 = { browser, active in
            EmbedderActiveSpy.calls.append((browser, active))
            return 1
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 30 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_embedder_active": unsafeBitCast(embedderActive, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}

/// Never attaches: these tests never start Chromium.
@MainActor private final class NeverAttachingSupervisor: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim: every symbol returns 0.
private nonisolated enum NothingShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
