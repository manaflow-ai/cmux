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
/// Every page shares one off-the-record profile (``CEFEngine/beginPagesProfile()``): like the WebKit pages'
/// non-persistent store, a page keeps nothing on disk, and no profile of the person's (their
/// extensions, cookies) touches a cmux page. Each page's key is a key of that profile, so it takes
/// the pages spare window the warm start built (`ChromiumWarmup`, p13-webui-016) instead of building
/// a window in the turn that opened it.
@MainActor
final class ChromiumPageHost: PageChromiumHosting {
    enum Failure: Error {
        /// The engine made a tab that is not a CEF tab.
        case notChromium
        /// The Chromium browser was not created (CEF failed to start, or the tab closed).
        case browserNotCreated
    }

    private let chromium: ChromiumEngineSlot
    private let enginePreference: @MainActor () -> BrowserDefaultEngine
    private weak var keyRouter: KeyRouter?
    /// The app's lanes: a page's screenshot reply is decoded on their `.cpu` lane.
    let work: BackgroundWork
    /// The app's main-thread scheduler: each page's crash watch flushes on it.
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - chromium: The app's Chromium engine slot: the engine is built when the first page opens in Chromium.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    ///   - work: The app's lanes (``PageChromiumHosting/work``).
    ///   - mainWork: The app's main-thread scheduler (``CEFPageChromiumPage``'s crash watch).
    init(chromium: ChromiumEngineSlot, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?,
         work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.chromium = chromium
        enginePreference = preference
        self.keyRouter = keyRouter
        self.work = work
        self.mainWork = mainWork
    }

    var preference: BrowserDefaultEngine { enginePreference() }

    var isAvailable: Bool { chromium.unavailableReason == nil }

    func serves(_ page: PageDescriptor) -> Bool { CEFPageSchemes.firstParty[page.id] != nil }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        #if DEBUG || CMUX_BENCH_HOOKS
        // Taken before any suspension: set by the traced chat's own page in this turn (``ChatOpenTrace``).
        let traced = ChatOpenTrace.shared.takeMakingTracedPage()
        #endif
        let cef = chromium.engine
        // Its own pane id: a page is never a tab of a browser pane's Chromium window.
        let configuration = BrowserTabConfiguration(profile: cef.beginPagesProfile(), pane: BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString))
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
        let chromiumPage = CEFPageChromiumPage(tab: tab, pageID: page.id, mainWork: mainWork)
        tab.delegate = chromiumPage
        tab.agentRelay.createBrowser()
        guard await tab.agentRelay.browserCreated() else {
            tab.close()
            throw Failure.browserNotCreated
        }
        return chromiumPage
    }
}
