import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A Chromium tab restores its saved entries into a browser made with no address (fork API 31,
/// `cmux_shim_tab_restore_entries`), loading the current one, instead of loading the saved page fresh with no
/// Back (audit 4, P7). A fork without the call loads the address, as before.
@MainActor @Suite(.serialized) struct CEFRestoreEntriesTests {
    static let session = BrowserSavedSession(entries: [
        BrowserSavedEntry(url: URL(string: "https://a.test/")!, title: "A"),
        BrowserSavedEntry(url: URL(string: "https://b.test/")!, title: "B"),
    ], current: 1)

    @Test func theEntriesGoToTheBrowserMadeWithoutAnAddress() throws {
        let rig = try EntriesRig(withCall: true)
        defer { rig.close() }
        _ = try rig.attachedTab(restoring: Self.session)
        #expect(EntriesSpy.createdURLs == [""])
        #expect(EntriesSpy.restored == [EntriesSpy.Restore(urls: ["https://a.test/", "https://b.test/"], titles: ["A", "B"], current: 1)])
        #expect(EntriesSpy.loads.isEmpty, "no fresh load of the saved page")
    }

    @Test func aForkWithoutTheCallLoadsTheAddress() throws {
        let rig = try EntriesRig(withCall: false)
        defer { rig.close() }
        _ = try rig.attachedTab(restoring: Self.session)
        #expect(EntriesSpy.restored.isEmpty)
        #expect(EntriesSpy.createdURLs == ["https://b.test/"])
    }
}

@MainActor private final class EntriesRig {
    let runtime: CEFRuntime
    let root: URL

    init(withCall: Bool) throws {
        EntriesSpy.reset(withCall: withCall)
        root = FileManager.default.temporaryDirectory.appending(path: "cef-restore-entries-\(UUID().uuidString)", directoryHint: .isDirectory)
        runtime = CEFRuntime(shim: try EntriesSpy.library(), storage: CEFProfileStorage(root: root))
    }

    /// A tab made as a relaunch makes it (`CEFEngine.makeReadyTab`: the entries, then the address), whose browser 7
    /// then exists.
    func attachedTab(restoring session: BrowserSavedSession) throws -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        tab.restoreEntriesOnCreation(session)
        tab.load(session.entries[session.current].url)
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

private nonisolated enum EntriesSpy {
    struct Restore: Equatable {
        var urls: [String]
        var titles: [String]
        var current: Int32
    }

    nonisolated(unsafe) static var withCall = true
    nonisolated(unsafe) static var createdURLs: [String] = []
    nonisolated(unsafe) static var restored: [Restore] = []
    nonisolated(unsafe) static var loads: [String] = []

    static func reset(withCall call: Bool) {
        withCall = call
        createdURLs = []
        restored = []
        loads = []
    }

    static func text(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let pointer else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 31 }
        let supported: @convention(c) () -> Int32 = { 1 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, url, _ in
            EntriesSpy.createdURLs.append(url.map { String(cString: $0) } ?? "")
            return 1
        }
        // cmux_shim_restore_entry: url, url_length, title, title_length, page_state, page_state_length.
        let restore: @convention(c) (Int32, UnsafeRawPointer?, Int32, Int32) -> Int32 = { _, entries, count, current in
            var urls: [String] = [], titles: [String] = []
            for index in 0..<Int(count) {
                let base = entries!.advanced(by: index * 6 * MemoryLayout<Int>.stride)
                let word = { (field: Int) in base.load(fromByteOffset: field * MemoryLayout<Int>.stride, as: Int.self) }
                urls.append(text(UnsafePointer(bitPattern: word(0)), word(1)))
                titles.append(text(UnsafePointer(bitPattern: word(2)), word(3)))
            }
            EntriesSpy.restored.append(Restore(urls: urls, titles: titles, current: current))
            return 1
        }
        let load: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { _, url in EntriesSpy.loads.append(url.map { String(cString: $0) } ?? "") }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_navigation_restore_supported": unsafeBitCast(supported, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_restore_entries": EntriesSpy.withCall ? unsafeBitCast(restore, to: UnsafeMutableRawPointer.self) : nil
            case "cmux_shim_load_url": unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
