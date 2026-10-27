@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 069 of plans/cmux-next/chrome-parity/p01-process.md: Chromium's page menu (CONTEXT_MENU, answered
/// with `context_menu_done`) and its downloads (DOWNLOAD_*, answered with `download_continue`) in host
/// mode. A token numbers a menu or a download of the host that sent it, and the next host numbers its own
/// from 1 again, so nothing cmux holds for an ended host's token may reach the next one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFHostModeMenuAndDownloadTests {
    // MARK: Context menus

    @Test func hostModeAMenuAnsweredWhileItsPageHasTheBrowserEndsIt() async throws {
        let runtime = try await Self.runtime(hostMode: true)
        let (tab, menus) = Self.tab(runtime)
        defer { withExtendedLifetime(tab) {} }

        runtime.showContextMenu(browser: Self.page, token: 2, x: 10, y: 20, itemsJSON: "[]", paramsJSON: "{}")
        try #require(menus.requests.last).complete(42)

        #expect(MenuSpy.done == ["2 42"])
    }

    /// The page's browser ended with the host while its menu was open: the token is the ended host's,
    /// and the next host may have given the same number to another page's menu.
    @Test func hostModeAMenuAnsweredAfterItsBrowserWentSendsNothing() async throws {
        let runtime = try await Self.runtime(hostMode: true)
        let (tab, menus) = Self.tab(runtime)
        defer { withExtendedLifetime(tab) {} }

        runtime.showContextMenu(browser: Self.page, token: 1, x: 10, y: 20, itemsJSON: "[]", paramsJSON: "{}")
        runtime.tabsByBrowser[Self.page] = nil
        try #require(menus.requests.last).complete(50100)

        #expect(MenuSpy.done.isEmpty, "an ended host's menu token reached the host after it")
    }

    /// In process the shim lives as long as the app: a late answer goes, and the shim drops a token it no
    /// longer holds.
    @Test func inProcessAMenuAnsweredAfterItsBrowserWentStillAnswers() async throws {
        let runtime = try await Self.runtime(hostMode: false)
        let (tab, menus) = Self.tab(runtime)
        defer { withExtendedLifetime(tab) {} }

        runtime.showContextMenu(browser: Self.page, token: 3, x: 10, y: 20, itemsJSON: "[]", paramsJSON: "{}")
        runtime.tabsByBrowser[Self.page] = nil
        try #require(menus.requests.last).complete(nil)

        #expect(MenuSpy.done == ["3 -1"])
    }

    @Test func aMenuForABrowserWithNoTabEndsAtOnce() async throws {
        let runtime = try await Self.runtime(hostMode: true)

        runtime.showContextMenu(browser: 99, token: 4, x: 0, y: 0, itemsJSON: "[]", paramsJSON: "{}")

        #expect(MenuSpy.done == ["4 -1"])
    }

    // MARK: Downloads

    /// The host ended while a download ran: its row ends interrupted (Chromium's CRASH reason) with Retry,
    /// and the next host's download 1 is a new download in a new row, never written into the old file.
    @Test func hostEndInterruptsRunningDownloadsAndTheNextHostsTokensAreNew() throws {
        let rig = try DownloadRig()
        defer { rig.clean() }
        let url = "https://a.test/f.zip"

        #expect(rig.downloads.download(url, browser: 3))
        rig.downloads.handle(.started(id: 1, browser: 3, url: url, suggestedName: "f.zip", totalBytes: nil))
        let first = try #require(rig.delivered.first)
        let firstPath = try #require(rig.answers.first?.path)

        rig.downloads.hostEnded()

        #expect(first.status == .failed("interrupted (\(CEFDownloads.crashReason))"))
        #expect(first.canRetry)
        #expect(rig.controls.isEmpty, "the host's end sent a download op")

        rig.downloads.handle(.started(id: 1, browser: 3, url: "https://a.test/g.zip", suggestedName: "g.zip", totalBytes: nil))

        #expect(rig.delivered.count == 2, "the next host's download 1 was taken as the ended host's")
        let second = try #require(rig.answers.last)
        #expect(second.id == 1)
        #expect(second.path != firstPath)
        #expect(rig.delivered.last?.filename == "g.zip")

        first.cancel()
        #expect(rig.controls.isEmpty, "the ended row sent a cancel to the next host's download")
    }

    /// A page's download waiting for its tab's automatic-downloads answer when the host ended: that answer
    /// is for no download, and the next host's download under the same token waits for its own.
    @Test func anAdmitAnswerForAnEndedHostsDownloadSendsNothing() throws {
        let rig = try DownloadRig()
        defer { rig.clean() }
        var decisions: [(AutomaticDownloadGate.Outcome, String?) -> Void] = []
        rig.downloads.admit = { _, decide in decisions.append(decide) }

        rig.downloads.handle(.started(id: 2, browser: 3, url: "https://a.test/old.zip", suggestedName: "old.zip", totalBytes: nil))
        rig.downloads.hostEnded()
        rig.downloads.handle(.started(id: 2, browser: 3, url: "https://a.test/new.zip", suggestedName: "new.zip", totalBytes: nil))
        #expect(decisions.count == 2)

        decisions[0](.allowed, nil)
        #expect(rig.answers.isEmpty, "the ended host's answer started the next host's download")
        #expect(rig.delivered.isEmpty)

        decisions[1](.allowed, nil)
        #expect(rig.answers.map(\.id) == [2])
        #expect(rig.delivered.map(\.filename) == ["new.zip"])
    }

    /// A Save Link As sent to the ended host never comes: the next host's download of the same link is the
    /// page's own, not the file the person chose.
    @Test func aChosenFileWaitingForTheEndedHostIsForgotten() throws {
        let rig = try DownloadRig()
        defer { rig.clean() }
        let link = try #require(URL(string: "https://a.test/c.zip"))
        let chosen = rig.folder.appending(path: "chosen.zip")

        #expect(rig.downloads.save(link, to: chosen, browser: 3))
        rig.downloads.hostEnded()
        rig.downloads.handle(.started(id: 1, browser: 3, url: link.absoluteString, suggestedName: "c.zip", totalBytes: nil))

        #expect(rig.delivered.first?.destination?.lastPathComponent == "c.zip")
    }

    /// The runtime's own host end (`CEFRuntime.hostEnded`, as the supervisor reports it) reaches the
    /// runtime's downloads (``CEFDownloads/forRuntime(_:)``): a running row ends interrupted with CRASH.
    @Test func theRuntimesHostEndInterruptsItsRunningDownloads() async throws {
        let runtime = try await Self.runtime(hostMode: true)
        let (tab, _) = Self.tab(runtime)
        defer { withExtendedLifetime(tab) {} }
        let rig = try RuntimeDownloads(runtime)
        defer { rig.clean() }
        let url = "https://a.test/f.zip"

        #expect(rig.downloads.download(url, browser: Self.page))
        rig.downloads.handle(.started(id: 1, browser: Self.page, url: url, suggestedName: "f.zip", totalBytes: nil))
        let row = try #require(rig.delivered.first)
        runtime.state = .ready
        runtime.hostEnded(Self.killed)

        #expect(row.status == .failed("interrupted (\(CEFDownloads.crashReason))"), "the host's end left its download running")
        #expect(row.canRetry)
    }

    /// The next host gives the tab a new browser id; the ended host's id names no tab. Retry of a row the
    /// host's end interrupted starts the download from the tab's new browser.
    @Test func retryAfterTheHostEndedStartsFromTheTabsNewBrowser() async throws {
        let runtime = try await Self.runtime(hostMode: true)
        let (tab, _) = Self.tab(runtime)
        defer { withExtendedLifetime(tab) {} }
        let rig = try RuntimeDownloads(runtime)
        defer { rig.clean() }
        let url = "https://a.test/f.zip"
        #expect(rig.downloads.download(url, browser: Self.page))
        rig.downloads.handle(.started(id: 1, browser: Self.page, url: url, suggestedName: "f.zip", totalBytes: nil))
        let row = try #require(rig.delivered.first)
        runtime.state = .ready
        runtime.hostEnded(Self.killed)

        // The next host is attached, and the tab gets its browser there.
        runtime.shim = try CEFShimLibrary.resolving(MenuSpy.symbol)
        runtime.state = .ready
        runtime.register(tab, browser: Self.page + 1)
        MenuSpy.downloads = []

        #expect(row.retry(), "Retry found no tab for the ended host's browser id")
        #expect(MenuSpy.downloads == ["\(Self.page + 1) \(url)"])
    }

    // MARK: Fixtures

    static let page: Int32 = 7
    static let killed = BrowserProcessExit(reason: .killed, code: 9, engine: .cef)

    /// A runtime that outlives the test (a tab's scheduled work reads it through an unowned reference); in
    /// host mode attached to the spy.
    private static func runtime(hostMode: Bool) async throws -> CEFRuntime {
        MenuSpy.reset()
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(MenuSpy.symbol), storage: HostRepliesHarness.storage())
        if hostMode {
            runtime.hostStart = try await HostRepliesHarness.attachedHost(over: { MenuSpy.symbol($0) })
        }
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    /// A tab whose browser is ``page``, with a delegate that keeps the menus it is asked to show.
    private static func tab(_ runtime: CEFRuntime) -> (CEFTab, MenuRequests) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: page)
        let menus = MenuRequests()
        tab.delegate = menus
        MenuSpy.done = []
        return (tab, menus)
    }
}

/// The page menus a tab asked its host to show.
@MainActor private final class MenuRequests: BrowserTabDelegate {
    private(set) var requests: [BrowserContextMenuRequest] = []

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        guard case .contextMenu(let request) = intent else { return }
        requests.append(request)
    }
}

/// `CEFDownloads` over a fake shim, writing into a folder of its own (``clean()`` removes it).
@MainActor private final class DownloadRig {
    /// What the fake shim was sent.
    @MainActor final class Sent {
        var answers: [(id: Int32, path: String)] = []
        var controls: [String] = []
    }

    let downloads: CEFDownloads
    let folder: URL
    private let sent: Sent
    private(set) var delivered: [BrowserDownload] = []

    var answers: [(id: Int32, path: String)] { sent.answers }
    var controls: [String] { sent.controls }

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cef-host-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sent = Sent()
        self.sent = sent
        downloads = CEFDownloads {
            CEFDownloadShim(start: { _, _ in true },
                            answer: { id, path in sent.answers.append((id, path)) },
                            control: { id, command in sent.controls.append("\(id) \(command)") })
        }
        downloads.directory = { folder }
        downloads.deliver = { [weak self] _, item in self?.delivered.append(item) }
    }

    func clean() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// `CEFDownloads.forRuntime` of a test runtime, writing into a folder of its own (``clean()`` removes it).
@MainActor private final class RuntimeDownloads {
    let downloads: CEFDownloads
    private let folder: URL
    private(set) var delivered: [BrowserDownload] = []

    init(_ runtime: CEFRuntime) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cef-runtime-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloads = CEFDownloads.forRuntime(runtime)
        downloads.directory = { folder }
        downloads.deliver = { [weak self] _, item in self?.delivered.append(item) }
    }

    func clean() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The shim of these tests: `context_menu_done` recorded as "token command", `download_url` as
/// "browser url"; every other function returns 0. In host mode the remote wire's entry points are
/// ``SpyRemoteWire``'s.
private nonisolated enum MenuSpy {
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var done: [String] = []
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var downloads: [String] = []

    static func reset() {
        done = []
        downloads = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let menuDone: @convention(c) (Int32, Int32, Int32) -> Void = { token, command, _ in
            MenuSpy.done.append("\(token) \(command)")
        }
        let downloadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, url in
            MenuSpy.downloads.append("\(browser) \(url.map { String(cString: $0) } ?? "")")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_context_menu_done": unsafeBitCast(menuDone, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_download_url": unsafeBitCast(downloadURL, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
