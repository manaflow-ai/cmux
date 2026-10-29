import AppKit
import CmuxNextBrowser
import CmuxNextDesign
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
/// the pages spare window the warm start built (`ChromiumWarmup`) instead of building
/// a window in the turn that opened it. The page tabs of one pane share that pane's page window
/// (``PageChromiumWindow``): the second page of a pane builds no window. A page tab runs no
/// browser-tab document script and attaches none of their DevTools bridges (``CEFEngine/makePagesTab(_:)``):
/// only its first paint is read. A page's ``PageChromiumOrigin`` is its tab's origin, and the slot's
/// launch order (``CEFLaunchDeferral``, 040) answers a restored page's origin and hidden start.
@MainActor
final class ChromiumPageHost: PageChromiumHosting {
    enum Failure: Error {
        /// The Chromium browser was not created (CEF failed to start, or the tab closed).
        case browserNotCreated
    }

    private let chromium: ChromiumEngineSlot
    private let enginePreference: @MainActor () -> BrowserDefaultEngine
    private weak var keyRouter: KeyRouter?
    /// The scheduler pages report their renderer's hang on (feature `pageHangNotice`); nil: they never do.
    private let hangWork: MainWorkScheduler?
    /// Pages post their calls on the runtime's page channel (feature `pageHostChannel`).
    private let pageChannel: Bool
    /// The default-off feature `pagePushChannel`: pages get host events and replies as data where the fork can.
    private let pushChannel: Bool
    /// The app's lanes: a page's screenshot reply is decoded on their `.cpu` lane.
    let work: BackgroundWork
    /// The app's main-thread scheduler: each page's crash watch flushes on it.
    private let mainWork: MainWorkScheduler
    /// The app's dialog center: a page's "Page unresponsive" card shows there.
    let dialogs: CmuxDialogCenter

    /// - Parameters:
    ///   - chromium: The app's Chromium engine slot: the engine is built when the first page opens in Chromium.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    ///   - work: The app's lanes (``PageChromiumHosting/work``).
    ///   - mainWork: The app's main-thread scheduler (``CEFPageChromiumPage``'s crash watch).
    ///   - dialogs: The app's dialog center (``PageChromiumHosting/dialogs``).
    ///   - hangWork: The app's main-thread scheduler when pages report their renderer's hang (feature
    ///     `pageHangNotice`, ``PageChromiumEvent/unresponsive``); nil: they never do.
    ///   - pageChannel: Pages post their calls on the runtime's page channel where it has one (feature
    ///     `pageHostChannel`, ``PageChromiumPage/pageHostEvent``); false: on their DevTools binding.
    ///   - pushChannel: The feature `pagePushChannel` (``PageChromiumPage/pushesToPage``).
    init(chromium: ChromiumEngineSlot, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?,
         work: BackgroundWork, mainWork: MainWorkScheduler, dialogs: CmuxDialogCenter, hangWork: MainWorkScheduler?,
         pageChannel: Bool = false, pushChannel: Bool = false) {
        self.chromium = chromium
        enginePreference = preference
        self.keyRouter = keyRouter
        self.work = work
        self.mainWork = mainWork
        self.dialogs = dialogs
        self.hangWork = hangWork
        self.pageChannel = pageChannel
        self.pushChannel = pushChannel
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

    func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, window: PageChromiumWindow?,
                  origin: PageChromiumOrigin) async throws -> any PageChromiumPage {
        #if DEBUG || CMUX_BENCH_HOOKS
        // Taken before any suspension: set by the traced chat's own page in this turn (``ChatOpenTrace``).
        let traced = ChatOpenTrace.shared.takeMakingTracedPage()
        #endif
        let cef = chromium.engine
        var configuration = Self.tabConfiguration(of: cef, chatOpen: chatOpen, window: window)
        configuration.origin = BrowserTabOrigin(origin)  // CEFEngine.makeTab's launch order is the only wait
        #if DEBUG || CMUX_BENCH_HOOKS
        if traced, ChatOpenTrace.shared.chromiumPane == nil { ChatOpenTrace.shared.chromiumPane = configuration.pane?.rawValue }
        #endif
        let tab = try await cef.makePagesTab(configuration)
        tab.keyRouter = keyRouter
        let chromiumPage = CEFPageChromiumPage(tab: tab, pageID: page.id, mainWork: mainWork, hangWork: hangWork,
                                               pageChannel: pageChannel, pushChannel: pushChannel)
        tab.delegate = chromiumPage
        tab.agentRelay.createBrowser()
        guard await tab.agentRelay.browserCreated() else {
            // The host ended before the browser existed (`CEFRuntime.hostEnded`): the page waits for its supervisor.
            let endedWithHost = tab.browserEndedWithHost
            tab.close()
            if endedWithHost { throw PageChromiumStartError.browserEnded }
            throw Failure.browserNotCreated
        }
        return chromiumPage
    }

    /// In cmux's own process a browser that ended cannot start again: the answer is ``PageChromiumSupervisorOutcome/gaveUp``,
    /// in the call. In the Chromium Host it comes once the host's supervisor started a new host, or refused to.
    func supervisorOutcome(then answer: @escaping @MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void) {
        guard let engine = chromium.built else { return answer(.gaveUp) }
        engine.restartPagesAfterHostEnd { answer($0 ? .restarted : .gaveUp) }
    }

    /// The configuration of a page tab in `window`'s page window, or in a window of its own when `window` is nil.
    static func tabConfiguration(of cef: CEFEngine, chatOpen: ChatOpenStages?, window: PageChromiumWindow?) -> BrowserTabConfiguration {
        cef.pagesTabConfiguration(chatOpen: chatOpen, pane: window.map(pane(of:)))
    }

    /// The CEF pane key of `window`: one Chromium window per pane of a main window.
    nonisolated static func pane(of window: PageChromiumWindow) -> BrowserPaneID {
        CEFEngine.pagesPane(window: window.window, pane: window.pane)
    }
}

extension BrowserTabOrigin {
    /// The engine's origin of a cmux page made with `origin` (``ChromiumPageHost/makePage(_:chatOpen:window:origin:)``).
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
