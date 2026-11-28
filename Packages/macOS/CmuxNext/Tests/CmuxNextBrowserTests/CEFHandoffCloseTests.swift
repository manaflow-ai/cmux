import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// #57470: the 2026-11-25 nightly SIGTRAP. GitHub's install page in a cmux tab redirected to the app's own
/// `cmux-nightly://integration/complete`; the tab handed it to the app (`BrowserExternalApps.openOwn`) and asked for
/// its own close, which the app ran as a person's close: `CEFTab.beginUserClose` called `cmux_shim_try_close`
/// (Chromium's `TryCloseBrowser`, the page's beforeunload) on the navigation Chromium had just cancelled for the
/// return link, and a CHECK in Chromium ended the app. The handoff's close is the flow's end: the tab closes without
/// asking its page, and the shim is never asked for a person's close.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFHandoffCloseTests {
    static let back = "cmux-test://integration/complete?state=a.b.c&code=x&installation_id=42&setup_action=install"

    @Test func theFlowTabsCloseAfterAHandoffNeverAsksThePage() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab(at: "https://github.com/apps/cmux/installations/new")
        // As the app does (`CloseUndoToasts.livePageDecidesClose`): the tab's close asks whether its page decides.
        var decided: [Bool] = []
        rig.intents.onClose = { decided.append(tab.pageDecidesUserClose()) }

        rig.runtime.handle(.externalURL(browser: Rig.browser, url: Self.back, userGesture: false))

        #expect(rig.routed.map(\.absoluteString) == [Self.back], "the return goes to the app's own route")
        #expect(rig.intents.closes == 1, "the flow's tab closes")
        #expect(decided == [false], "the close does not wait for the page")
        #expect(ShimLog.tryCloses == 0, "a person's close (TryCloseBrowser) never runs for the handoff's tab")
    }

    /// The same tab before any handoff: a person's close still lets the page decide (its beforeunload runs first).
    @Test func aPersonsCloseOfALiveTabStillLetsThePageDecide() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab(at: "https://github.com/apps/cmux/installations/new")
        #expect(tab.pageDecidesUserClose())
        #expect(ShimLog.tryCloses == 1)
    }

    /// A tab the person was already using (not opened for the flow) takes the return and stays open: no close at all.
    @Test func aTabNotOpenedForTheFlowStaysOpen() throws {
        let rig = try Rig()
        defer { rig.close() }
        _ = try rig.committedTab(at: "https://news.example/")
        rig.runtime.handle(.externalURL(browser: Rig.browser, url: Self.back, userGesture: false))
        #expect(rig.routed.map(\.absoluteString) == [Self.back])
        #expect(rig.intents.closes == 0)
        #expect(ShimLog.tryCloses == 0)
    }

    // MARK: Rig (as CEFPageClosingGroundTests')

    @MainActor final class Intents: BrowserTabDelegate {
        var closes = 0
        var onClose: () -> Void = {}
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            guard case .close = intent else { return }
            closes += 1
            onClose()
        }
    }

    @MainActor final class Rig {
        static let browser: Int32 = 31
        let runtime: CEFRuntime
        let root: URL
        let intents = Intents()
        var routed: [URL] = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        private let apps = BrowserExternalApps.shared
        private let saved: (schemes: Set<String>, route: (@MainActor (URL) -> Void)?, handoff: (@MainActor (URL) -> Bool)?, closes: (@MainActor (URL?) -> Bool)?)

        init() throws {
            ShimLog.tryCloses = 0
            root = FileManager.default.temporaryDirectory.appending(path: "cef-handoff-close-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
            saved = (apps.ownSchemes, apps.openOwnURL, apps.isOwnHandoff, apps.closesHandoffTab)
            apps.ownSchemes = ["cmux-test"]
            apps.openOwnURL = { [weak self] in self?.routed.append($0) }
            apps.isOwnHandoff = { $0.host == "integration" }
            apps.closesHandoffTab = { $0?.host == "github.com" }
        }

        /// A shown tab whose browser exists and whose first page, `url`, committed.
        func committedTab(at url: String) throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.delegate = intents
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            runtime.handle(.loadStart(browser: Self.browser, url: url, fromPost: false))
            try #require(tab.firstCommittedURL?.absoluteString == url || tab.committedURL?.absoluteString == url, "SETUP: \(url) did not commit")
            return tab
        }

        func close() {
            apps.ownSchemes = saved.schemes
            apps.openOwnURL = saved.route
            apps.isOwnHandoff = saved.handoff
            apps.closesHandoffTab = saved.closes
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.closeAfterTest()
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs and hosts: each rig lives to the end of the test process.
            Self.kept.append(self)
        }

        static var kept: [Rig] = []
    }
}

/// What the fake shim was asked (the shim is called on the main thread).
private nonisolated enum ShimLog {
    /// `cmux_shim_try_close` calls: a person's close, which runs the page's beforeunload.
    nonisolated(unsafe) static var tryCloses = 0

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 28 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        // 0: the page's beforeunload runs first, as for a live page.
        let tryClose: @convention(c) (Int32) -> Int32 = { _ in
            ShimLog.tryCloses += 1
            return 0
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_try_close": unsafeBitCast(tryClose, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
