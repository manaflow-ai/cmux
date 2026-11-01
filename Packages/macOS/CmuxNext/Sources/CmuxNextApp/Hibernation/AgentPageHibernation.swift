import AppKit
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Lets hidden agent chat pages go and freezes them (cx-x15rz): the policy and its clocks are
/// ``HiddenChatPages``; this is the App's side of it. Each chat tab's page is a web view with its own
/// web content process (about 75 MB), and before this it stayed until the tab closed. A page let go
/// keeps what ``AgentPaneWakeState`` carries (chips, shell text, scroll) and acpmux's draft, but not an
/// open menu or popover, the caret, a queued prompt being edited or an IME composition (Leo, 2026-10-26:
/// "why does cmux-next's browser keep refreshing and reloading?"); its tab keeps its session, so showing
/// it again builds the page on the same chat (``AgentTabStore/view(for:)``), which acpmux replays with
/// its draft. Its last frame is drawn under the pane until the new page paints.
///
/// The App keeps a page that is a New Tab page or another machine's chat, or in which a shell command
/// ran (closing the page ends the command or drops its output), and keeps awake a New Tab page, a Chief
/// chat and a crashed page.
@MainActor
final class AgentPageHibernation: HiddenChatPagesHost {
    static var minimumHidden: Double { HiddenChatPages<AgentPageHibernation>.minimumHidden }

    /// The agent tab store once the App made it (no agent tab yet: nothing to release).
    private let store: () -> AgentTabStore?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    /// The clocks and what they decide.
    private(set) lazy var pages: HiddenChatPages<AgentPageHibernation> = HiddenChatPages(
        host: self, deadline: DemandTimer(owner: "AgentPageHibernation"), freezeDeadline: DemandTimer(owner: "AgentPageFreeze"))
    /// The acpmux turn state of the tab's chat; injected by the App.
    var turnState: (String) -> AgentTurnState? = { _ in nil }
    /// The acpmux turn watch is up. While it is down no chat's turn is known, so every chat counts as busy.
    var turnsWatched: () -> Bool = { true }
    /// What the page holds that acpmux does not (attachments, shell text, scroll), kept with its
    /// tab when it lets go; nil when a connected page does not answer (tests set it: their page
    /// never loads).
    var wakeState: @MainActor (AgentPaneView) async -> AgentPaneWakeState? = { await $0.wakeState(limit: .seconds(3)) }
    var isPinned: (String) -> Bool = { _ in false }
    /// The pane still hosting tab `key`'s page lets it go (it shows the tab again on demand).
    var displace: (String) -> Void = { _ in }
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    /// The page's freeze control: its Chromium tab, nil for a WebKit page (a seam for tests).
    var freezer: @MainActor (AgentPaneView) -> (any BrowserFreezing)? = { ($0.chromiumPage as? CEFPageChromiumPage)?.tab }
    /// The page will show in Chromium but its browser is still being made: no freeze control yet, so
    /// a due page is looked at again (a seam for tests).
    var waitsForFreezer: @MainActor (AgentPaneView) -> Bool = { $0.waitsForChromium }
    /// Whether tab `key` draws now (`TabContentCache.isRendering`); injected by the App. A page built
    /// while its tab does not draw (restored or opened in the background) starts its hidden clock at
    /// the next plan, as an adopted browser tab does.
    var isRendering: (String) -> Bool = { _ in true }
    private var turnObservation: Task<Void, Never>?

    init(tabs: @escaping () -> AgentTabStore?) {
        store = tabs
    }

    /// Wired to the App: never makes the agent tab store (that starts acpmux), follows the panes'
    /// presentation changes, and lets the pane holding a released page go.
    convenience init(services: AppServices) {
        self.init(tabs: { [weak services] in services?.madeAgentTabs })
        isPinned = { [weak services] key in services?.locateTabOnAnyMachine(key)?.0.pinned ?? false }
        turnState = { [weak services] key in
            guard let tabs = services?.madeAgentTabs, var (record, _) = tabs.lookup(tabs.resolve(key)) else { return nil }
            // The session the page runs, as its rebuild uses it: a refused bind leaves the record on the old one.
            record.session = tabs.existingView(key)?.model.sessionId ?? tabs.session(of: key)
            return AgentTurnStateStore.shared.state(for: record)
        }
        // A run without the watch (showcase, the mock pane) has no turns to wait for.
        turnsWatched = { AgentTurnStateFeed.shared == nil || AgentTurnStateStore.shared.watching }
        displace = { [weak services] key in services?.cache.presenter(of: key)?.surfaceWasDisplaced(key) }
        let cache = services.cache
        isRendering = { [weak cache] key in cache?.isRendering(key) ?? true }
        cache.presentationChanges.subscribe("agent-page-hibernation") { [weak self, weak cache] in
            guard let cache else { return }
            self?.sync(cache.presentationChanges.changedKeys) { cache.isRendering($0) }
        }
        followTurns(AgentTurnStateStore.shared)
    }

    /// A turn that ends, or the watch coming back, makes its hidden page due again (a busy page
    /// has no deadline).
    func followTurns(_ turns: AgentTurnStateStore) {
        turnObservation?.cancel()
        turnObservation = Task { [weak self] in
            for await _ in ObservationStream({ (turns.stateRevision, turns.watching) }) {
                self?.replan()
            }
        }
    }

    // The planner's surface, as the App and the tests call it.
    var hasDeadline: Bool { pages.hasDeadline }
    var frozen: Set<String> { pages.frozen }
    var hasFreezeDeadline: Bool { pages.hasFreezeDeadline }
    func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) { pages.update(setting: setting, pressure: pressure) }
    func sync(_ changed: Set<String>? = nil, _ isRendering: (String) -> Bool) { pages.sync(changed, isRendering) }
    func forget(_ key: String) { pages.forget(key) }
    func replan() { pages.replan() }
    func keepsPage(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? { pages.keepsPage(key, onScreen: onScreen) }
    func keepsAwake(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? { pages.keepsAwake(key, onScreen: onScreen) }
    @discardableResult
    func releaseForWorkspace(_ key: String) -> HibernationPlanner.Exemption? { pages.releaseForWorkspace(key) }
    func pageBuilt(_ key: String) { pages.pageBuilt(key) }
    func holdAwake(_ held: Bool) { pages.holdAwake(held) }

    // MARK: HiddenChatPagesHost

    func hibernationPages() -> [String: AgentPaneView]? { store()?.views }
    func hibernationPage(_ key: String) -> AgentPaneView? { store()?.existingView(key) }
    func pageDraws(_ key: String) -> Bool { isRendering(key) }
    func pageClock() -> ContinuousClock.Instant { now() }
    func pagePinned(_ key: String) -> Bool { isPinned(key) }
    func pageTurnsKnown() -> Bool { turnsWatched() }
    func pageTurnBusy(_ key: String) -> Bool { turnState(key).map { $0 == .working || $0 == .needsInput } ?? false }
    func freezeControl(of page: AgentPaneView) -> (any BrowserFreezing)? { freezer(page) }
    func setFrozen(_ control: any BrowserFreezing, _ frozen: Bool) -> Bool { control.setFrozen(frozen) }
    func setPageWork(_ page: AgentPaneView, _ work: (@MainActor () -> Void)?) { page.model.transport.beforePageWork = work }
    func dropReleasedFrame(_ key: String) { store()?.launchImages.drop(key) }

    /// A chat of this Mac's acpmux with a session, off screen, not a New Tab page, and no shell
    /// command run in it.
    func pageMayRelease(_ key: String, onScreen: Bool) -> Bool {
        guard let tabs = store() else { return false }
        let key = tabs.resolve(key)
        // A crashed page keeps its notice: a rebuild would reload it without the person's Reload.
        guard let view = tabs.views[key], !view.showsCrashNotice, !(onScreen && Self.isOnScreen(view)), view.model.newTab == nil, !view.model.shell.hasRuns,
              tabs.newTabPages[key] == nil, let (record, _) = tabs.lookup(key),
              AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost, listedHere: true) == .local,
              tabs.daemonForTab(key)?.isLocal != false else { return false }
        return (tabs.sessions[key] ?? view.model.sessionId ?? record.session) != nil
            && tabs.remoteSeeds[key] == nil && tabs.remoteCreations[key] == nil && tabs.remoteStarts[key] == nil
    }

    /// A page in Chromium (or still making its browser), not a crashed or New Tab page, not a Chief chat.
    func pageMayFreeze(_ key: String, onScreen: Bool) -> Bool {
        guard let tabs = store(), let view = tabs.existingView(key), freezer(view) != nil || waitsForFreezer(view) else { return false }
        let stored = tabs.resolve(key)
        // A crashed page keeps its notice; a New Tab page follows its own parking (the spare pool).
        if view.showsCrashNotice || view.model.newTab != nil || tabs.newTabPages[stored] != nil { return false }
        // The Chief's own chats stay as they are.
        if let (record, _) = tabs.lookup(stored),
           AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost, listedHere: true) == .chief {
            return false
        }
        return !(onScreen && Self.isOnScreen(view))
    }

    private static func isOnScreen(_ view: AgentPaneView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// Keeps the page's frame and what it holds that acpmux does not, then lets the page go if it
    /// is still the same hidden page.
    func releasePage(_ key: String) {
        guard let tabs = store(), let view = tabs.existingView(key), let started = pages.beginRelease(key) else { return }
        let readWake = wakeState
        let hiddenFor = started.hiddenFor
        let pressure = pages.pressure
        let cause = started.forWorkspace ? "workspace-idle hidden=\(hiddenFor)s" : pressure == .normal ? "timeout hidden=\(hiddenFor)s" : "memory-pressure=\(pressure.rawValue) hidden=\(hiddenFor)s"
        Task { @MainActor [weak self] in
            let wake = await readWake(view)
            let frame = await Self.frame(view)
            guard let self else { return }
            pages.endRelease(key)
            // A connected page that did not say what it holds (a large attachment still encoding)
            // stays: letting it go would drop its chips. The next plan asks again.
            if wake == nil, view.model.hasHandshake {
                logger.info("agent page \(key, privacy: .public) kept: no wake state in time")
                return
            }
            // The page may have shown, changed or got busy (a turn started) while it was asked
            // for its frame or the frame was encoded: then it stays, and the next plan decides.
            guard pages.isDue(key, page: view) else { return replan() }
            if let frame { await tabs.launchImages.hold(key, frame.image, size: frame.size, appearance: frame.appearance) }
            guard pages.isDue(key, page: view) else {
                tabs.launchImages.drop(key)
                return replan()
            }
            displace(key)
            // The tab keeps its session and every other state: the next show builds the page again.
            let stored = tabs.resolve(key)
            if let session = view.model.sessionId { tabs.sessions[stored] = session }
            tabs.wakeStates[stored] = wake.flatMap { $0.isEmpty ? nil : $0 }
            tabs.views[stored] = nil
            tabs.retirer.retire(view)
            tabs.stopCustomizationWhenUnused()
            pages.released(key)
            // Notice, not info: the field log keeps it (the page is built again when shown).
            logger.notice("released agent page \(key, privacy: .public) cause=\(cause, privacy: .public); it is built again when shown")
        }
    }

    /// The page as last drawn; nil when it does not answer in time (it then shows its loading
    /// state when it comes back).
    private static func frame(_ view: AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? {
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await view.pageImage().flatMap { image in image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size, appearance) } }
        }
        return frame.flatMap { $0 }
    }
}
