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
/// a window in the turn that opened it. A page's ``PageChromiumOrigin`` is its tab's origin, and the slot's
/// launch order (``CEFLaunchDeferral``, 040) answers a restored page's origin and hidden start (p08-startup-041).
@MainActor
final class ChromiumPageHost: PageChromiumHosting {
    enum Failure: Error {
        /// The Chromium browser was not created (CEF failed to start, or the tab closed).
        case browserNotCreated
    }

    private let chromium: ChromiumEngineSlot
    private let enginePreference: @MainActor () -> BrowserDefaultEngine
    private weak var keyRouter: KeyRouter?
    /// The app's lanes: a page's screenshot reply is decoded on their `.cpu` lane.
    let work: BackgroundWork

    /// - Parameters:
    ///   - chromium: The app's Chromium engine slot: the engine is built when the first page opens in Chromium.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    ///   - work: The app's lanes (``PageChromiumHosting/work``).
    init(chromium: ChromiumEngineSlot, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?,
         work: BackgroundWork) {
        self.chromium = chromium
        enginePreference = preference
        self.keyRouter = keyRouter
        self.work = work
    }

    /// The slot's launch order's origin (``CEFLaunchDeferral/restoredOrigin(isShown:wasStarted:)``): a page view starts once.
    func restoredOrigin(isShown: Bool) -> PageChromiumOrigin {
        PageChromiumOrigin(chromium.launchOrder.restoredOrigin(isShown: isShown, wasStarted: false))
    }

    /// The slot's launch order's hidden start, the path a hidden restored browser tab takes too.
    func startHidden(when node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void) {
        chromium.launchOrder.startHidden(when: node, start)
    }

    var preference: BrowserDefaultEngine { enginePreference() }

    var isAvailable: Bool { chromium.unavailableReason == nil }

    func serves(_ page: PageDescriptor) -> Bool { CEFPageSchemes.firstParty[page.id] != nil }

    func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, origin: PageChromiumOrigin) async throws -> any PageChromiumPage {
        #if DEBUG || CMUX_BENCH_HOOKS
        // Taken before any suspension: set by the traced chat's own page in this turn (``ChatOpenTrace``).
        let traced = ChatOpenTrace.shared.takeMakingTracedPage()
        #endif
        let cef = chromium.engine
        var configuration = cef.pagesTabConfiguration(chatOpen: chatOpen)
        configuration.origin = BrowserTabOrigin(origin)  // CEFEngine.makeTab's launch order is the only wait
        #if DEBUG || CMUX_BENCH_HOOKS
        if traced, ChatOpenTrace.shared.chromiumPane == nil { ChatOpenTrace.shared.chromiumPane = configuration.pane?.rawValue }
        #endif
        let tab = try await cef.makePagesTab(configuration)
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

extension BrowserTabOrigin {
    /// The engine's origin of a cmux page made with `origin` (``ChromiumPageHost/makePage(_:chatOpen:origin:)``).
    nonisolated init(_ origin: PageChromiumOrigin) {
        self = switch origin {
        case .user: .user
        case .automation: .automation
        case .restoreVisible: .restoreVisible
        case .restoreHidden: .restoreHidden
        }
    }
}

extension PageChromiumOrigin {
    /// The page side of the engine's `origin` (``ChromiumPageHost/restoredOrigin(isShown:)``).
    nonisolated init(_ origin: BrowserTabOrigin) {
        self = switch origin {
        case .user: .user
        case .automation: .automation
        case .restoreVisible: .restoreVisible
        case .restoreHidden: .restoreHidden
        }
    }
}
