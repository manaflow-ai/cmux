@testable import CmuxNextBrowser
import Foundation
import Testing

/// A pane host whose last tab left is removed from `CEFRuntime.hosts`, as Chromium
/// closes a `Browser` whose tab strip emptied (chrome/browser/ui/browser.cc, `Browser::TabStripEmpty`).
/// Every cmux page has its own key (`cmux-page-<UUID>`), so a host kept after its page closed
/// was never used again: 20 opens and closes left 20 hosts. An untaken spare keeps its host.
/// Driven against a stand-in shim whose `cmux_shim_create_window` reports the window started.
@MainActor @Suite(.serialized) struct CEFPaneHostReleaseTests {
    private let pages = BrowserProfileID(rawValue: UUID())

    @Test func twentyPagesOpenedAndClosedLeaveNoHost() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = runtime.hosts.count
        for index in 0..<20 {
            let key = CEFPaneKey(pane: BrowserPaneID(rawValue: "cmux-page-\(UUID().uuidString)"), profile: pages, offTheRecord: true)
            let browser = Int32(100 + index)
            let tab = try Self.openLive(key, browser: browser, runtime: runtime)
            #expect(runtime.hosts.count == start + 1, "the open page's host")
            // Chromium destroys the browser after the close (OnBeforeClose).
            tab.close()
            runtime.handle(.beforeClose(browser: browser))
            #expect(runtime.hosts[key] == nil, "page \(index) left its host behind")
        }
        #expect(runtime.hosts.count == start)
    }

    /// A browser pane's tabs closing one by one: its host stays while a tab is left, and goes with
    /// the last (the pane closed). The pane's next tab gets a new host.
    @Test func aBrowserPaneHostGoesWithItsLastTab() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = runtime.hosts.count
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: BrowserProfileID(rawValue: UUID()))
        let first = try Self.openLive(key, browser: 10, runtime: runtime)
        let host = try #require(runtime.hosts[key])
        let second = CEFTab(id: .random(), profile: key.profile, host: host, runtime: runtime)
        host.add(second)

        second.close()
        #expect(runtime.hosts[key] === host, "one tab is left")
        first.close()
        runtime.handle(.beforeClose(browser: 10))
        #expect(runtime.hosts[key] == nil)
        #expect(runtime.hosts.count == start)
        #expect(runtime.host(for: key) !== host, "the pane's next tab gets a new host")
    }

    /// The pane that took the spare closed its tab before it joined the window: the window is the
    /// spare again (`CEFSpareWindow.giveBack`) and keeps its host.
    @Test func aSpareGivenBackKeepsItsHost() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.prepare(.browser, runtime: runtime))
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 10, request: request, window: 10))
        let spare = try #require(spares.host(of: .browser))
        let start = runtime.hosts.count

        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        #expect(host === spare)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        tab.close()

        #expect(spares.host(of: .browser) === spare, "the spare again")
        #expect(runtime.hosts[spare.key] === spare, "keyed as a spare, still in the table")
        #expect(runtime.hosts.count == start)

        // Dropped, its placeholder (its last tab) goes, and the host with it (`hostEmptied`).
        let spareKey = spare.key
        spares.drop(.browser, runtime: runtime)
        #expect(runtime.hosts[spareKey] == nil)
        #expect(runtime.hosts.count == start - 1)
    }

    /// Chromium closed an untaken spare's placeholder itself: the host is empty and still the
    /// spare, so `hostEmptied` leaves it in both tables (`CEFSpareWindow.state(of:)` says `closed`).
    @Test func anUntakenSpareWhosePlaceholderClosedKeepsItsEntry() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.prepare(.browser, runtime: runtime))
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 10, request: request, window: 10))
        let spare = try #require(spares.host(of: .browser))

        runtime.handle(.beforeClose(browser: 10))

        #expect(spare.tabs.isEmpty, "the placeholder left")
        #expect(spares.host(of: .browser) === spare)
        #expect(spares.state(of: .browser) == .closed)
        #expect(runtime.hosts[spare.key] === spare)
    }

    /// A taken spare given back when another spare of its kind was made since: its window has no
    /// use left, and the deferred close of its placeholder takes it out of the table (`hostEmptied`).
    @Test func aTakenSpareGivenBackBesideANewerSpareLeavesTheTable() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.prepare(.browser, runtime: runtime))
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: 10, request: request, window: 10))
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let taken = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: .default, host: taken, runtime: runtime)
        taken.add(tab)
        #expect(spares.prepare(.browser, runtime: runtime), "the next spare")
        let newer = try #require(spares.host(of: .browser))

        tab.close()
        #expect(runtime.hosts[key] === taken, "the close waits for a later run-loop pass")
        let end = ContinuousClock.now + .seconds(2)
        while runtime.hosts[key] != nil, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }

        #expect(runtime.hosts[key] == nil)
        #expect(taken.tabs.isEmpty)
        #expect(spares.host(of: .browser) === newer)
        #expect(runtime.hosts[newer.key] === newer)
    }

    /// A host that emptied after another host took its key leaves the newer host in place.
    @Test func anEmptiedHostLeavesTheHostThatNowHoldsItsKey() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.popupPrefix + UUID().uuidString), profile: .default)
        let replaced = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: .default, host: replaced, runtime: runtime)
        replaced.add(tab)
        let newer = CEFPaneHost(key: key, runtime: runtime)
        runtime.hosts[key] = newer

        tab.close()

        #expect(replaced.tabs.isEmpty)
        #expect(runtime.hosts[key] === newer)
    }

    /// Opens a tab of `key` whose window came up as `browser`.
    private static func openLive(_ key: CEFPaneKey, browser: Int32, runtime: CEFRuntime) throws -> CEFTab {
        let host = runtime.host(for: key)
        let tab = CEFTab(id: .random(), profile: key.profile, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
        #expect(tab.browserID == browser)
        return tab
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn
    /// (`CEFPaneHost.windowCreated`), after the test returned.
    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-release-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try ReleaseSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the window started (it stays
/// `creating` until a test sends its OnAfterCreated); every other function does nothing and returns 0.
private nonisolated enum ReleaseSpyShim {
    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
