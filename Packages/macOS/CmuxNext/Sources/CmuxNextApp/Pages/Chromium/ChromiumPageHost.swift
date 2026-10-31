import AppKit
import CmuxNextBrowser
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The app's ``PageChromiumHosting``: cmux's own React pages in CEF tabs, so `browser.defaultEngine`
/// decides their engine as it does for browser tabs. Made once at the composition root
/// (`AppDelegate`) and handed to ``PageWebView/chromiumHosting``.
///
/// Every page shares one off-the-record profile: like the WebKit pages' non-persistent store, a
/// page keeps nothing on disk, and no profile of the person's (their extensions, cookies) touches a
/// cmux page.
@MainActor
final class ChromiumPageHost: PageChromiumHosting {
    enum Failure: Error {
        /// The engine made a tab that is not a CEF tab.
        case notChromium
        /// The Chromium browser was not created (CEF failed to start, or the tab closed).
        case browserNotCreated
    }

    private let cef: CEFEngine
    private let enginePreference: @MainActor () -> BrowserDefaultEngine
    private weak var keyRouter: KeyRouter?
    private let paneFocus: @MainActor (PageWebView) -> Bool
    private var pageProfile: BrowserProfileID?

    /// - Parameters:
    ///   - cef: The app's Chromium engine.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    ///   - paneFocus: ``focusViewChanged(_:)``: applies the focus model of the pane showing the page again.
    init(cef: CEFEngine, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?, paneFocus: @escaping @MainActor (PageWebView) -> Bool) {
        self.cef = cef
        enginePreference = preference
        self.keyRouter = keyRouter
        self.paneFocus = paneFocus
    }

    func focusViewChanged(_ page: PageWebView) -> Bool { paneFocus(page) }
    var preference: BrowserDefaultEngine { enginePreference() }

    var isAvailable: Bool { cef.unavailableReason == nil }

    func serves(_ page: PageDescriptor) -> Bool { CEFPageSchemes.firstParty[page.id] != nil }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        #if DEBUG || CMUX_BENCH_HOOKS
        // Taken before any suspension: set by the traced chat's own page in this turn (``ChatOpenTrace``).
        let traced = ChatOpenTrace.shared.takeMakingTracedPage()
        #endif
        let profile = pageProfile ?? cef.stores.offTheRecord.begin()
        pageProfile = profile
        // Its own pane id: a page is never a tab of a browser pane's Chromium window.
        let configuration = BrowserTabConfiguration(profile: profile, pane: BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString))
        #if DEBUG || CMUX_BENCH_HOOKS
        if traced, ChatOpenTrace.shared.chromiumPane == nil { ChatOpenTrace.shared.chromiumPane = configuration.pane?.rawValue }
        #endif
        let made = try await cef.makeTab(configuration)
        guard let tab = made as? CEFTab else {
            made.close()
            throw Failure.notChromium
        }
        tab.pageThemeSurface = .internalPage
        tab.keyRouter = keyRouter
        let chromiumPage = CEFPageChromiumPage(tab: tab, pageID: page.id)
        tab.delegate = chromiumPage
        tab.agentRelay.createBrowser()
        guard await tab.agentRelay.browserCreated() else {
            tab.close()
            throw Failure.browserNotCreated
        }
        return chromiumPage
    }
}
