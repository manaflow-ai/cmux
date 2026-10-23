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
    private var pageProfile: BrowserProfileID?
    /// One page's CEF tab per display frame, never in the frame of the action that showed it.
    private let startFrames: ChromiumPageFrameBudget
    /// Freezes hidden pages after the hibernation's grace (`CmuxPageFreezing`); set by the
    /// hibernation when it starts.
    weak var freezePolicy: (any PageFreezePolicy)?

    /// - Parameters:
    ///   - cef: The app's Chromium engine.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    ///   - startFrames: Spreads the pages' CEF tabs over display frames, one per frame.
    init(cef: CEFEngine, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?,
         startFrames: ChromiumPageFrameBudget = ChromiumPageFrameBudget()) {
        self.cef = cef
        enginePreference = preference
        self.keyRouter = keyRouter
        self.startFrames = startFrames
    }

    var preference: BrowserDefaultEngine { enginePreference() }

    var isAvailable: Bool { cef.unavailableReason == nil }

    func serves(_ page: PageDescriptor) -> Bool { CEFPageSchemes.firstParty[page.id] != nil }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        #if DEBUG
        // Taken before any suspension: set by the traced chat's own page in this turn (``ChatOpenTrace``).
        let traced = ChatOpenTrace.shared.takeMakingTracedPage()
        #endif
        // Not in the turn that showed the page (a switch's commit frame), and one page per frame.
        await startFrames.nextFrame()
        // The page closed while it waited: no CEF tab for it.
        try Task.checkCancellation()
        let profile = pageProfile ?? OffTheRecordProfiles.shared.begin()
        pageProfile = profile
        // Its own pane id: a page is never a tab of a browser pane's Chromium window.
        let configuration = BrowserTabConfiguration(profile: profile, pane: BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString))
        #if DEBUG
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
