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

    /// - Parameters:
    ///   - cef: The app's Chromium engine.
    ///   - preference: Reads `browser.defaultEngine` now (the settings snapshot, so pages made while
    ///     windows restore already follow the file).
    ///   - keyRouter: Gets the app's shortcuts from a focused Chromium page.
    init(cef: CEFEngine, preference: @escaping @MainActor () -> BrowserDefaultEngine, keyRouter: KeyRouter?) {
        self.cef = cef
        enginePreference = preference
        self.keyRouter = keyRouter
    }

    var preference: BrowserDefaultEngine { enginePreference() }

    var isAvailable: Bool { cef.unavailableReason == nil }

    func serves(_ page: PageDescriptor) -> Bool { CEFPageSchemes.firstParty[page.id] != nil }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        defer { scheduleSpare() }
        if let taken = await takeSpare() {
            #if DEBUG
            traceChromiumPane(taken.pane, of: page)
            #endif
            return wrap(taken.tab, as: page)
        }
        let pane = Self.newPane()
        #if DEBUG
        traceChromiumPane(pane, of: page)
        #endif
        let tab = try await makeBrowser(pane: pane)
        return wrap(tab, as: page)
    }

    // MARK: The spare page

    /// The page tab made ahead of the next page (``spareDelay`` after a page is made, at most one):
    /// its Chromium window and browser exist, on about:blank, so the next page starts its document
    /// at once instead of after a window and a browser are built (about 80 ms of a chat open's
    /// 120 ms before its document starts, Leo 2026-10-22: "flickers the initial thing ... then it
    /// just goes to black screen for a while"). Never made before a page needs Chromium, nor
    /// while pages open in WebKit; dropped when one would be refused (``dropSpare()``).
    private var spare: (tab: CEFTab, pane: String)?
    /// The one-shot refill: the next spare is made this long after a page took or made one, so its
    /// window is built while nothing is opening, not in the open that took the last one.
    static let spareDelay: Duration = .milliseconds(1_500)
    private let spareTimer = DemandTimer(owner: "chromiumPageHost.spare")
    private var makingSpare = false

    private static func newPane() -> String {
        // Its own pane id: a page is never a tab of a browser pane's Chromium window.
        "cmux-page-" + UUID().uuidString
    }

    /// A new page tab with its browser created, on its own pane's window.
    private func makeBrowser(pane: String) async throws -> CEFTab {
        let profile = pageProfile ?? OffTheRecordProfiles.shared.begin()
        pageProfile = profile
        let made = try await cef.makeTab(BrowserTabConfiguration(profile: profile, pane: BrowserPaneID(rawValue: pane)))
        guard let tab = made as? CEFTab else {
            made.close()
            throw Failure.notChromium
        }
        tab.pageThemeSurface = .internalPage
        tab.keyRouter = keyRouter
        tab.agentRelay.createBrowser()
        guard await tab.agentRelay.browserCreated() else {
            tab.close()
            throw Failure.browserNotCreated
        }
        return tab
    }

    private func wrap(_ tab: CEFTab, as page: PageDescriptor) -> any PageChromiumPage {
        let chromiumPage = CEFPageChromiumPage(tab: tab, pageID: page.id)
        tab.delegate = chromiumPage
        return chromiumPage
    }

    /// The spare, when it is still live and pages still open in Chromium.
    private func takeSpare() async -> (tab: CEFTab, pane: String)? {
        guard let taken = spare else { return nil }
        spare = nil
        guard preference == .chromium, isAvailable, await taken.tab.agentRelay.browserCreated() else {
            taken.tab.close()
            return nil
        }
        return taken
    }

    /// Makes the next spare ``spareDelay`` from now, unless one is there or being made, or pages
    /// do not open in Chromium.
    private func scheduleSpare() {
        guard spare == nil, !makingSpare, preference == .chromium, isAvailable else { return }
        spareTimer.scheduleIfIdle(after: Self.spareDelay) { @MainActor [weak self] in
            await self?.makeSpare()
        }
    }

    private func makeSpare() async {
        guard spare == nil, !makingSpare, preference == .chromium, isAvailable, cef.isRunning else { return }
        makingSpare = true
        defer { makingSpare = false }
        let pane = Self.newPane()
        guard let tab = try? await makeBrowser(pane: pane) else { return }
        // A page may have opened meanwhile and the engine changed: keep one spare, only for Chromium.
        guard spare == nil, preference == .chromium else { return tab.close() }
        spare = (tab, pane)
    }

    /// Closes the spare (pages no longer open in Chromium, or Chromium shuts down).
    func dropSpare() {
        spareTimer.cancel()
        spare?.tab.close()
        spare = nil
    }

    #if DEBUG
    /// The first agent page made while a chat open is traced is that open's (``ChatOpenTrace``).
    private func traceChromiumPane(_ pane: String, of page: PageDescriptor) {
        let trace = ChatOpenTrace.shared
        if trace.isArmed, trace.chromiumPane == nil, page.id == ChatOpenTrace.agentPageID { trace.chromiumPane = pane }
    }
    #endif
}
