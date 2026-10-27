import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p01-process-093: a Chromium tab keeps each history entry's page state (scroll offsets,
/// typed form text) as the fork reports it, saves it with the entry, and a restored tab gives the
/// entries back with theirs through `cmux_shim_tab_restore_entries`. Against a spy shim at fork API 31.
@MainActor @Suite(.serialized) struct CEFPageStateTests {
    /// The acceptance's restore: each entry goes to the fork with its URL, title and page state, the
    /// tab loads no URL of its own, and the restored states are the tab's from then on, so the next
    /// save keeps them for entries the fork does not report again.
    @Test func aRestoredTabSendsEachEntryWithItsPageState() throws {
        let rig = try PageStateRig()
        defer { rig.close() }
        let a = try #require(URL(string: "https://example.com/a")), form = try #require(URL(string: "https://example.com/form"))
        let entries = BrowserSavedSession(entries: [
            BrowserSavedEntry(url: a, title: "A", pageState: "state-a"),
            BrowserSavedEntry(url: form, title: "Form", scrollY: 480, pageState: "scroll=480;input=typed"),
        ], current: 1)
        let tab = try rig.attachedTab(restoring: entries)
        #expect(PageStateSpy.restored == [
            PageStateSpy.Record(url: a.absoluteString, title: "A", pageState: "state-a"),
            PageStateSpy.Record(url: form.absoluteString, title: "Form", pageState: "scroll=480;input=typed"),
        ])
        #expect(PageStateSpy.restoredCurrent == [1])
        #expect(PageStateSpy.loads.isEmpty, "the restore is the tab's first navigation")
        #expect(tab.nativePageStates() == [0: BrowserEntryPageState(url: a, state: "state-a"),
                                            1: BrowserEntryPageState(url: form, state: "scroll=480;input=typed")])
    }

    /// A refused entries restore (here -3, a page state that does not decode) falls back to the
    /// navigation state the tab also had, and with none to the page's address: the back/forward list
    /// is not lost and the tab is never left blank.
    @Test func aRefusedEntriesRestoreFallsBackToTheNavigationStateThenTheURL() throws {
        let form = try #require(URL(string: "https://example.com/form"))
        let entries = BrowserSavedSession(entries: [BrowserSavedEntry(url: form, title: "Form", pageState: "bad")], current: 0)
        let rig = try PageStateRig()
        defer { rig.close() }
        PageStateSpy.restoreCode = -3
        let tab = try rig.attachedTab(restoring: entries, navigationState: "nav-state", loading: form)
        #expect(PageStateSpy.restoredCurrent == [0], "the entries were offered first")
        #expect(PageStateSpy.navigationRestores == ["nav-state"], "then the navigation state")
        #expect(PageStateSpy.loads.isEmpty)
        #expect(tab.nativePageStates().isEmpty, "a refused restore seeds no page state")

        let bare = try PageStateRig()
        defer { bare.close() }
        PageStateSpy.restoreCode = -3
        _ = try bare.attachedTab(restoring: entries, navigationState: nil, loading: form)
        #expect(PageStateSpy.navigationRestores.isEmpty)
        #expect(PageStateSpy.loads == [form.absoluteString], "with no navigation state, the address loads")
    }

    /// After the Chromium Host ended with the tab's browser, its next browser restores the entries
    /// and page states the tab kept from the fork's reports (a Reload, here), not only its URL; a
    /// load of another address before then drops them.
    @Test func theNextHostsBrowserRestoresTheKeptEntriesWithTheirPageStates() throws {
        let rig = try PageStateRig()
        defer { rig.close() }
        let form = try #require(URL(string: "https://example.com/form"))
        let tab = try rig.attachedTab(restoring: nil, loading: form)
        PageStateSpy.entries = ["https://example.com/a", form.absoluteString]
        PageStateSpy.states = [0: "sa", 1: "scroll=480;input=typed"]
        tab.pageStateReported(index: 0)
        tab.pageStateReported(index: 1)
        tab.readReportedPageStates()

        rig.endHost(tab)
        PageStateSpy.entries = []
        PageStateSpy.loads = []
        tab.reload()
        try rig.attachNext(tab, browser: 8)
        #expect(PageStateSpy.restored.map(\.pageState) == ["sa", "scroll=480;input=typed"])
        #expect(PageStateSpy.restored.map(\.url) == ["https://example.com/a", "https://example.com/form"])
        #expect(PageStateSpy.restoredCurrent.last == 1)
        #expect(PageStateSpy.loads.isEmpty, "the restore is the new browser's first navigation")
        #expect(tab.nativePageStates()[1]?.state == "scroll=480;input=typed", "the restored states stay the tab's")

        PageStateSpy.restored = []
        rig.endHost(tab)
        let elsewhere = try #require(URL(string: "https://example.com/elsewhere"))
        tab.load(elsewhere)
        try rig.attachNext(tab, browser: 9)
        #expect(PageStateSpy.restored.isEmpty, "a load elsewhere restores nothing")
    }

    /// A state past the host's per-entry bound is kept as none, as the host pushes it.
    @Test func aPageStatePastTheBoundIsKeptAsNone() throws {
        let rig = try PageStateRig()
        defer { rig.close() }
        let tab = try rig.attachedTab(restoring: nil)
        PageStateSpy.entries = ["https://example.com/log"]
        PageStateSpy.states = [0: String(repeating: "x", count: CEFTabPageStates.maxStateBytes + 1)]
        tab.pageStateReported(index: 0)
        tab.readReportedPageStates()
        #expect(tab.nativePageStates().isEmpty)
    }

    /// A burst of the fork's reports is one read per entry, in a later turn; each state is kept with
    /// the URL its entry shows, and only a change bumps the revision the history writer watches.
    @Test func reportsAreReadOncePerEntryAndKeptWithTheirURL() throws {
        let rig = try PageStateRig()
        defer { rig.close() }
        let tab = try rig.attachedTab(restoring: nil)
        PageStateSpy.entries = ["https://example.com/a", "https://example.com/b"]
        PageStateSpy.states = [0: "s0", 1: "s1"]
        tab.pageStateReported(index: 0)
        tab.pageStateReported(index: 1)
        tab.pageStateReported(index: 0)
        #expect(PageStateSpy.reads.isEmpty, "nothing is read inside the fork's call")
        tab.readReportedPageStates()
        #expect(PageStateSpy.reads.sorted() == [0, 1], "one read per entry")
        let a = try #require(URL(string: "https://example.com/a")), b = try #require(URL(string: "https://example.com/b"))
        #expect(tab.nativePageStates() == [0: BrowserEntryPageState(url: a, state: "s0"), 1: BrowserEntryPageState(url: b, state: "s1")])
        #expect(tab.sessionStateRevision == 1)

        tab.pageStateReported(index: 1)
        tab.readReportedPageStates()
        #expect(tab.sessionStateRevision == 1, "the same state is no change")
        PageStateSpy.states[1] = nil
        tab.pageStateReported(index: 1)
        tab.readReportedPageStates()
        #expect(tab.nativePageStates()[1] == nil && tab.sessionStateRevision == 2, "an entry with none forgets its state")
    }

    /// The feature off, a fork below API 31, or saved entries with no page state restore as before.
    @Test func onlyAKeepingTabOnAnAPI31ForkRestoresEntries() throws {
        let rig = try PageStateRig()
        defer { rig.close() }
        let tab = try rig.unbornTab()
        let url = try #require(URL(string: "https://example.com/"))
        let withState = BrowserSavedSession(entries: [BrowserSavedEntry(url: url, pageState: "s")], current: 0)
        let without = BrowserSavedSession(entries: [BrowserSavedEntry(url: url)], current: 0)
        #expect(!tab.restoresPageStates(withState), "feature off")
        tab.pageStates.keeps = true
        #expect(tab.restoresPageStates(withState))
        #expect(!tab.restoresPageStates(without), "no entry has a page state")
        PageStateSpy.version = 30
        #expect(!tab.restoresPageStates(withState), "a fork below API 31")
    }

    /// A saved session takes an engine entry's page state only while that entry shows the URL the
    /// state was read at; with no engine list, none.
    @Test func aSavedSessionTakesPageStatesOnlyForTheirURL() throws {
        let a = try #require(URL(string: "https://example.com/a")), b = try #require(URL(string: "https://example.com/b"))
        let other = try #require(URL(string: "https://example.com/other"))
        let native = BrowserNavigationList(entries: [BrowserNavigationEntry(url: a, title: "A"), BrowserNavigationEntry(url: b, title: "B")], current: 1)
        let states = [0: BrowserEntryPageState(url: a, state: "sa"), 1: BrowserEntryPageState(url: other, state: "stale")]
        let session = BrowserRestoredHistory.empty.session(around: native, shown: BrowserNavigationEntry(url: b, title: "B"), pageStates: states)
        #expect(session.entries.map(\.pageState) == ["sa", nil])
        let alone = BrowserRestoredHistory.empty.session(around: nil, shown: BrowserNavigationEntry(url: a, title: "A"), pageStates: states)
        #expect(alone.entries.map(\.pageState) == [nil])
    }

    /// `cmux_shim_restore_entry` records: each string's pointer and byte length, NULL and 0 for none.
    @Test func restoreRecordsPointAtEachStringWithItsLength() throws {
        let url = try #require(URL(string: "https://example.com/é"))
        let entries = [BrowserSavedEntry(url: url, title: "Tïtle", pageState: "AA/+=="), BrowserSavedEntry(url: url)]
        let records = CEFShimPageStateOps.withRecords(entries) { pointer, count in PageStateSpy.records(pointer, count: count) }
        #expect(records == [PageStateSpy.Record(url: url.absoluteString, title: "Tïtle", pageState: "AA/+=="),
                            PageStateSpy.Record(url: url.absoluteString, title: nil, pageState: nil)])
    }

    // MARK: Rig

    @MainActor final class PageStateRig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            PageStateSpy.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-state-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PageStateSpy.symbol), storage: CEFProfileStorage(root: root))
        }

        func unbornTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            return tab
        }

        /// A tab that keeps page states, whose browser 7 exists (AFTER_CREATED), restoring `entries`
        /// with `navigationState` as their fallback, at `url`; as `CEFEngine.makeTab` sets it up.
        func attachedTab(restoring entries: BrowserSavedSession?, navigationState: String? = nil, loading url: URL? = nil) throws -> CEFTab {
            let tab = try unbornTab()
            tab.pageStates.keeps = true
            if let entries, tab.restoresPageStates(entries) { tab.pageStates.pendingEntries = entries }
            tab.pendingRestore = navigationState
            if let url { tab.load(url) }
            try attachNext(tab, browser: 7)
            return tab
        }

        /// The Chromium Host ended with `tab`'s browser (`CEFRuntime.hostEnded`): its browsers and
        /// windows went with it.
        func endHost(_ tab: CEFTab) {
            runtime.tabsByBrowser = [:]
            runtime.pendingWindows = [:]
            tab.host.hostEnded()
            tab.hostEnded(BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef))
        }

        /// `tab`'s browser `browser` exists (AFTER_CREATED of its window).
        func attachNext(_ tab: CEFTab, browser: Int32) throws {
            tab.host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
            try #require(tab.browserID == browser)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// A fake fork behind the shim at API 31: the tab's entries and each one's page state, the restores
/// and loads it gets; every other function does nothing.
private nonisolated enum PageStateSpy {
    struct Record: Equatable {
        var url: String?
        var title: String?
        var pageState: String?
    }

    nonisolated(unsafe) static var version: Int32 = 31 // crash-allow: the suite is serialized and the shim is called on the main actor
    nonisolated(unsafe) static var entries: [String] = [] // crash-allow: as above
    nonisolated(unsafe) static var states: [Int32: String] = [:] // crash-allow: as above
    nonisolated(unsafe) static var reads: [Int32] = [] // crash-allow: as above
    nonisolated(unsafe) static var restored: [Record] = [] // crash-allow: as above
    nonisolated(unsafe) static var restoredCurrent: [Int32] = [] // crash-allow: as above
    nonisolated(unsafe) static var loads: [String] = [] // crash-allow: as above
    nonisolated(unsafe) static var restoreCode: Int32 = 1 // crash-allow: as above
    nonisolated(unsafe) static var navigationRestores: [String] = [] // crash-allow: as above

    static func reset() {
        version = 31
        entries = []
        states = [:]
        reads = []
        restored = []
        restoredCurrent = []
        loads = []
        restoreCode = 1
        navigationRestores = []
    }

    /// The records `cmux_shim_tab_restore_entries` got: three (pointer, length) words pairs each.
    static func records(_ pointer: UnsafeRawPointer?, count: Int32) -> [Record] {
        guard let pointer, count > 0 else { return [] }
        let words = pointer.assumingMemoryBound(to: UInt.self)
        func text(_ word: Int) -> String? {
            let length = Int(words[word + 1])
            guard let start = UnsafeRawPointer(bitPattern: words[word]), length > 0 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: start, count: length), as: UTF8.self)
        }
        return (0 ..< Int(count)).map { Record(url: text($0 * 6), title: text($0 * 6 + 2), pageState: text($0 * 6 + 4)) }
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { PageStateSpy.version }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let free: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { Darwin.free($0) }
        let navigationEntries: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = { _ in
            let list = PageStateSpy.entries.map { ["url": $0, "title": ""] }
            guard let data = try? JSONSerialization.data(withJSONObject: ["entries": list, "current": max(0, list.count - 1)]) else { return nil }
            return strdup(String(decoding: data, as: UTF8.self))
        }
        let entryPageState: @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>? = { _, index in
            PageStateSpy.reads.append(index)
            return PageStateSpy.states[index].flatMap { strdup($0) }
        }
        let restoreEntries: @convention(c) (Int32, UnsafeRawPointer?, Int32, Int32) -> Int32 = { _, records, count, current in
            PageStateSpy.restored = PageStateSpy.records(records, count: count)
            PageStateSpy.restoredCurrent.append(current)
            return PageStateSpy.restoreCode
        }
        let restoreNavigation: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, state in
            if let state { PageStateSpy.navigationRestores.append(String(cString: state)) }
            return 1
        }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in
            if let url { PageStateSpy.loads.append(String(cString: url)) }
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_free": unsafeBitCast(free, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_navigation_entries": unsafeBitCast(navigationEntries, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_entry_page_state": unsafeBitCast(entryPageState, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_restore_entries": unsafeBitCast(restoreEntries, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_load_url": unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_restore_navigation": unsafeBitCast(restoreNavigation, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
