import CmuxNextSettings
import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// The page host hooks the agent pane needs (agent pane move, H2 H3 H5 H10 H11): engine options,
/// bounded crash reloads with a notice, the navigation policy, first-party roots in other module
/// bundles. (Per-page CSP sources are PageCSP.)
@MainActor
@Suite struct PageHostHooksTests {
    private let page = PageDescriptor(id: "cmux.history", resource: "history", namespaces: ["cmux.history."])

    // MARK: H5 navigation

    @Test func thePagesOwnOriginIsAllowedAndNeverReachesTheHook() {
        var asked = 0
        let policy = PageNavigation.policy(for: URL(string: "cmux-page://cmux.history/#/x"), page: page, userClicked: false,
                                           mainFrame: true, hook: { _ in asked += 1; return .cancel })
        #expect(policy == .allow)
        #expect(asked == 0)
    }

    @Test func withoutAHookOnlyAClickedMainFrameLinkOpensOutside() {
        let url = URL(string: "https://example.com/")
        func policy(_ clicked: Bool, _ main: Bool) -> PageNavigation.Policy {
            PageNavigation.policy(for: url, page: page, userClicked: clicked, mainFrame: main, hook: nil)
        }
        #expect(policy(true, true) == .openExternal)
        // An automatic redirect never opens a tab, and a frame never leaves the page.
        #expect(policy(false, true) == .cancel)
        #expect(policy(true, false) == .cancel)
        #expect(PageNavigation.policy(for: URL(string: "about:blank"), page: page, userClicked: true, mainFrame: true, hook: nil) == .cancel)
        #expect(PageNavigation.policy(for: nil, page: page, userClicked: true, mainFrame: true, hook: nil) == .cancel)
    }

    @Test func aHookDecidesOtherOrigins() {
        var seen: [PageNavigation] = []
        let url = URL(string: "http://127.0.0.1:5173/")!
        let policy = PageNavigation.policy(for: url, page: page, userClicked: false, mainFrame: false) { navigation in
            seen.append(navigation)
            return .allow
        }
        #expect(policy == .allow)
        #expect(seen == [PageNavigation(url: url, userClicked: false, mainFrame: false)])
    }

    // MARK: H3 crash reloads

    @Test func aPageThatKeepsCrashingStopsReloadingAndShowsTheNotice() throws {
        let root = try Self.root()
        let view = try #require(PageWebView(descriptor: Self.appPage, root: root, routes: []))
        var notices = 0
        view.onCrashNotice = { _ in notices += 1 }
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        view.now = { clock }
        for _ in 0..<PageCrashReloads.limit {
            view.webViewWebContentProcessDidTerminate(view.webView)
            clock += 1
        }
        #expect(notices == 0)
        view.webViewWebContentProcessDidTerminate(view.webView)
        #expect(notices == 1)
        // The Reload button forgets the crashes.
        view.reloadAfterCrashes()
        view.webViewWebContentProcessDidTerminate(view.webView)
        #expect(notices == 1)
        view.close()
    }

    // MARK: H2 engine options

    @Test func fullFrameRateTurnsOffTheNear60FPSFeature() throws {
        let root = try Self.root()
        let standard = try #require(PageWebView(descriptor: Self.appPage, root: root, routes: []))
        let full = try #require(PageWebView(descriptor: Self.appPage, root: root, routes: [],
                                            options: PageEngineOptions(fullFrameRate: true)))
        defer { standard.close(); full.close() }
        let key = PageEngineOptions.near60FPSFeature
        // A WebKit without the feature has nothing to change.
        guard let near60 = full.webView.configuration.preferences.isWebKitFeatureEnabled(key) else { return }
        #expect(near60 == false)
        #expect(standard.webView.configuration.preferences.isWebKitFeatureEnabled(key) == true)
    }

    // MARK: H10 first-party roots in other bundles

    @Test func aRegisteredRootServesItsFirstPartyPageAndCannotBeMoved() throws {
        let root = try Self.root()
        let other = try Self.root()
        // A first-party id no other test registers (the registry is process-wide).
        let page = PageDescriptor(id: "cmux.keybindings", resource: "no-such-resource", namespaces: ["cmux.keybindings."])
        #expect(!PageWebView.mayServe(page, from: root))
        PageID.registerBundledRoot(root, for: "cmux.keybindings")
        PageID.registerBundledRoot(other, for: "cmux.keybindings")
        #expect(PageWebView.mayServe(page, from: root))
        #expect(!PageWebView.mayServe(page, from: other))
        // Only a first-party id can be registered.
        PageID.registerBundledRoot(other, for: "cmux.agentx")
        PageID.registerBundledRoot(other, for: "com.example.app")
        #expect(PageID.bundledRoot(for: "cmux.agentx") == nil)
        #expect(PageID.bundledRoot(for: "com.example.app") == nil)
    }

    private static let appPage = PageDescriptor(id: "com.example.hooks", resource: "hooks", namespaces: ["com.example.hooks."])

    private static func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "page-hooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<!doctype html><title>t</title>".utf8).write(to: dir.appending(path: "index.html"))
        return dir
    }
}
