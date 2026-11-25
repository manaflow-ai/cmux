import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// #32912: each Chromium tab event (a tab inserted or removed, an extension action changed) read
/// `cmux_ext_actions` for every tab of the pane. That call has Chromium draw and PNG-encode every
/// extension icon on the main thread, so the cost grew with the tab count: 16-23 ms after each
/// Shift-Cmd-L and 7-16 ms after each DevTools close. Chrome's toolbar draws the active tab's
/// actions only and reads a background tab's when it becomes active. Here the tab on screen reads
/// at once, a hidden tab when it shows, an inserted tab only its own, and a removed tab none.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFExtensionActionsRefreshTests {
    /// A pane whose live Chromium window (1) holds `count` tabs, browsers 10, 11, ..., the first shown.
    static func pane(tabs count: Int) throws -> (runtime: CEFRuntime, host: CEFPaneHost, tabs: [CEFTab], container: NSView, root: URL) {
        ExtActionsSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-ext-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try ExtActionsSpyShim.library(), storage: CEFProfileStorage(root: root))
        // Outlives the test: a shown tab schedules work that reads its runtime after the test returned.
        _ = Unmanaged.passRetained(runtime)
        ExtActionsSpyShim.runtime = runtime
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = CEFPaneHost(key: key, runtime: runtime)
        // The runtime's tab events reach the hosts it holds.
        runtime.hosts[key] = host
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        var tabs = [first]
        for _ in 1..<count {
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            tabs.append(tab)
        }
        #expect(tabs.compactMap(\.browserID) == (0..<Int32(count)).map { 10 + $0 }, "every tab has its browser")
        ExtActionsSpyShim.reads = []
        return (runtime, host, tabs, container, root)
    }

    /// The Shift-Cmd-L case: a new tab joins the pane's window. Only the new tab can have new
    /// actions, and it is not on screen yet: no other tab reads its icons.
    @Test func aTabInsertedReadsNoOtherTabsIcons() throws {
        let pane = try Self.pane(tabs: 6)
        defer { try? FileManager.default.removeItem(at: pane.root) }
        let inserted = try #require(pane.tabs.last?.browserID)
        pane.runtime.handle(.tab(.inserted, browser: inserted, window: 1, value: 0))
        #expect(ExtActionsSpyShim.reads.allSatisfy { $0 == inserted }, "read the icons of other tabs: \(ExtActionsSpyShim.reads)")
        #expect(ExtActionsSpyShim.reads.count <= 1)
    }

    /// The DevTools close case: a tab left the window. No remaining tab's actions changed.
    @Test func aTabRemovedReadsNoIcons() throws {
        let pane = try Self.pane(tabs: 6)
        defer { try? FileManager.default.removeItem(at: pane.root) }
        pane.runtime.handle(.tab(.removed, browser: 99, window: 1, value: 0))
        #expect(ExtActionsSpyShim.reads.isEmpty, "read icons for a removed tab: \(ExtActionsSpyShim.reads)")
    }

    /// An extension's action changed: the tab on screen reads at once, the hidden tabs read when
    /// they show, each once.
    @Test func anActionChangeReadsTheShownTabNowAndAHiddenTabWhenItShows() throws {
        let pane = try Self.pane(tabs: 6)
        defer { try? FileManager.default.removeItem(at: pane.root) }
        pane.runtime.handle(.tab(.extensionActionsChanged, browser: 10, window: 1, value: 0))
        #expect(ExtActionsSpyShim.reads == [10], "only the tab on screen reads its icons now")

        ExtActionsSpyShim.reads = []
        let hidden = pane.tabs[3]
        pane.host.conceal(pane.tabs[0])
        pane.host.present(hidden, in: pane.container)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(ExtActionsSpyShim.reads == [13], "the hidden tab reads its icons once it shows")

        ExtActionsSpyShim.reads = []
        pane.host.conceal(hidden)
        pane.host.present(pane.tabs[0], in: pane.container)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(ExtActionsSpyShim.reads.isEmpty, "a tab whose icons did not change reads none on a switch")
    }

    /// Review of #32967: `browser.extension.run` may name a background tab. Its actions changed while it
    /// was hidden, so the command reads them first (once), as the tab never showed to read them itself.
    @Test func aCommandOnAHiddenTabReadsItsStaleActionsFirst() throws {
        let pane = try Self.pane(tabs: 3)
        defer { try? FileManager.default.removeItem(at: pane.root) }
        pane.runtime.handle(.tab(.extensionActionsChanged, browser: 10, window: 1, value: 0))
        ExtActionsSpyShim.reads = []
        pane.tabs[2].readExtensionsForCommand()
        #expect(ExtActionsSpyShim.reads == [12], "the command read the hidden tab's changed actions")
        ExtActionsSpyShim.reads = []
        pane.tabs[2].readExtensionsForCommand()
        pane.tabs[0].readExtensionsForCommand()
        #expect(ExtActionsSpyShim.reads.isEmpty, "actions already current are not read again")
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the browser started, `cmux_shim_tab_add`
/// gives the next browser id (11, 12, ...) and runs its OnAfterCreated before it returns, as
/// production's shim does; `cmux_shim_ext_actions` records the browser whose icons it was asked for;
/// `cmux_shim_fork_api_version` reports 27; every other function does nothing and returns 0.
private nonisolated enum ExtActionsSpyShim {
    nonisolated(unsafe) static var reads: [Int32] = []
    nonisolated(unsafe) static var nextBrowser: Int32 = 11
    nonisolated(unsafe) static weak var runtime: CEFRuntime?

    static func reset() {
        reads = []
        nextBrowser = 11
        runtime = nil
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, _ in
            let browser = ExtActionsSpyShim.nextBrowser
            ExtActionsSpyShim.nextBrowser += 1
            MainActor.assumeIsolated {
                ExtActionsSpyShim.runtime?.handle(.afterCreated(browser: browser, request: 0, window: 1))
            }
            return browser
        }
        let extActions: @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>? = { browser, _ in
            ExtActionsSpyShim.reads.append(browser)
            return nil
        }
        let tabWindowID: @convention(c) (Int32) -> Int32 = { _ in 1 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_ext_actions": unsafeBitCast(extActions, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_window_id": unsafeBitCast(tabWindowID, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
