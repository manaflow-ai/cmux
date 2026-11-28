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
import CmuxNextTabs
import CmuxNextWakeups
import os
/// Lets hidden agent chat pages go and freezes them (cx-x15rz): the policy and its clocks are
/// ``HiddenChatPages``; this is the App's side of it. Each chat tab's page is a web view with its own
/// renderer allocation (WebKit may share a process across pages). A page let go
/// keeps what ``AgentPaneWakeState`` carries (chips, shell text, scroll) and acpmux's draft, but not an
/// open menu or popover, the caret, a queued prompt being edited or an IME composition (Leo, 2026-10-26:
/// "why does cmux-next's browser keep refreshing and reloading?"); its tab keeps its session, so showing
/// it again builds the page on the same chat (``AgentTabStore/view(for:)``), which acpmux replays with
/// its draft. Its last frame is drawn under the pane until the new page paints.
///
/// Another machine's chat and pages with shell runs stay loaded. Untouched local New Tabs use
/// the warm-page cap and keep their native context; edited New Tabs stay loaded. New Tabs,
/// Chief chats and crashed pages do not freeze.
@MainActor
final class AgentPageHibernation: HiddenChatPagesHost {
    static var minimumHidden: Double { HiddenChatPages<AgentPageHibernation>.minimumHidden }
    static var keptRecheck: Double { HiddenChatPages<AgentPageHibernation>.keptRecheck }

    /// The agent tab store once the App made it (no agent tab yet: nothing to release).
    private let store: () -> AgentTabStore?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    /// The chat renderer recycle's App (``startRendererRecycle(services:)``; nil while it is off) and its state.
    private weak var recycleServices: AppServices?
    private var recycleState = CEFChatRendererRecycle()
    private var recycleRunning = false
    private let recycleSettle = DemandTimer(owner: "AgentPageHibernation.recycleSettle")
    private lazy var recycleInput = WindowServerInputEvents()
    /// The clocks and what they decide.
    private(set) lazy var pages: HiddenChatPages<AgentPageHibernation> = HiddenChatPages(
        host: self, deadline: DemandTimer(owner: "AgentPageHibernation"), freezeDeadline: DemandTimer(owner: "AgentPageFreeze"))
    /// The acpmux session of the tab's chat, whose turn, work and archive tag `turns` mirrors; injected by the App.
    var chat: (String) -> AgentSessionRef? = { _ in nil }
    var turns = AgentTurnStateStore.shared // the mirror of acpmux's facts (tests set their own)
    /// The acpmux turn watch is up. While it is down no chat's turn is known, so every chat counts as busy.
    var turnsWatched: () -> Bool = { true }
    /// What the page holds that acpmux does not (attachments, shell text, scroll), kept with its
    /// tab when it lets go; nil when a connected page does not answer (tests set it: their page
    /// never loads).
    var wakeState: @MainActor (AgentPaneView) async -> AgentPaneWakeState? = { await $0.wakeState(limit: .seconds(3)) }
    /// A usable first frame is required before an automatic default release.
    var snapshot: @MainActor (AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? = { await AgentPaneHibernationCapture(view: $0).frame() }
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
    /// Builds a shown chat again when that lets a later renderer exit (``RendererPackingRun``); nil in tests.
    private(set) var packing: RendererPackingRun<AgentPageHibernation>?
    /// The engine's live pages and a chat's browser id; the pane showing tab `key` lets its page go, runs `swap` and
    /// shows the tab again, its new page held off the window until it painted (false: no pane shows it). The App's.
    var livePages: () -> [RendererPacking.LivePage] = { [] }
    var browserID: (AgentPaneView) -> Int32? = { _ in nil }
    var reshow: (_ key: String, _ swap: () -> Void) -> Bool = { _, _ in false }
    private func scopedKey(_ storageKey: String, in tabs: AgentTabStore) -> AgentTabKey {
        let parsed = AgentTabKey(relaunchStorageKey: storageKey)
        return parsed.machine.isEmpty ? tabs.tabKey(parsed.key) : parsed
    }
    init(tabs: @escaping () -> AgentTabStore?) {
        store = tabs
    }

    /// Wired to the App: never makes the agent tab store (that starts acpmux), follows the panes'
    /// presentation changes, and lets the pane holding a released page go.
    convenience init(services: AppServices) {
        self.init(tabs: { [weak services] in services?.madeAgentTabs })
        isPinned = { [weak services] key in
            guard let services else { return false }
            let parsed = AgentTabKey(relaunchStorageKey: key)
            let scoped = parsed.machine.isEmpty ? services.madeAgentTabs?.tabKey(parsed.key) ?? parsed : parsed
            return (scoped.machine.isEmpty ? services.locateTab(scoped.key) : services.locateTab(scoped.key, onMachine: scoped.machine))?.0.pinned ?? false
        }
        chat = { [weak services] key in
            guard let tabs = services?.madeAgentTabs else { return nil }
            let parsed = AgentTabKey(relaunchStorageKey: key)
            let scoped = parsed.machine.isEmpty ? tabs.tabKey(parsed.key) : parsed
            guard var (record, _) = tabs.record(for: tabs.resolvedKey(scoped)) else { return nil }
            // The session the page runs, as its rebuild uses it: a refused bind leaves the record on the old one.
            record.session = tabs.existingView(scoped.key, machine: scoped.machine)?.model.sessionId ?? tabs.sessions[tabs.resolvedKey(scoped)] ?? record.session
            return record
        }
        // A run without the watch (showcase, the mock pane) has no turns to wait for.
        turnsWatched = { AgentTurnStateFeed.shared == nil || AgentTurnStateStore.shared.watching }
        displace = { [weak services] key in services?.cache.presenter(of: key)?.surfaceWasDisplaced(key) }
        let cache = services.cache
        isRendering = { [weak cache] key in cache?.isRendering(key) ?? true }
        pages.pairedFace = { [weak services, weak cache] key in // Toggle Terminal and Chat: a chat whose pane draws its terminal face
            guard let services, let cache, let (tab, pane) = services.locateTab(AgentTabKey(relaunchStorageKey: key).key), tab.kind != .pty,
                  let session = TerminalChatHandler.chatSession(of: tab, services: services)?.agentSessionId else { return false }
            return pane.tabs.contains { $0.kind == .pty && $0.agent?.harnessSessionID == session && cache.isRendering($0.id) }
        }
        cache.presentationChanges.subscribe("agent-page-hibernation") { [weak self, weak cache] in
            guard let cache else { return }
            self?.sync(cache.presentationChanges.changedKeys) { cache.isRendering($0) }
        }
        followTurns(AgentTurnStateStore.shared)
        let cef = cache.cef
        livePages = { cef.rendererPages.map { .init(browser: $0.browserID, origin: $0.origin, rendererClients: $0.rendererClients, exited: $0.exited) } }
        browserID = { cef.browserID(showing: $0.focusTarget) }
        reshow = { [weak services] key, swap in
            guard let services, let tabs = services.madeAgentTabs, let pane = services.cache.presenter(of: key) as? PaneController,
                  pane.currentTabKey == key else { return false }
            pane.letGo(key, parks: false)
            swap()
            tabs.rebuiltAway.insert(key)
            if services.presentation.showNow(pane) { tabs.rebuiltAway.remove(key) } // shown: its page is held already
            return true
        }
        packing = RendererPackingRun(host: self, cap: CEFEngine.cmuxPagesPerRenderer, timer: DemandTimer(owner: "AgentPageRendererPacking"))
    }

    /// A turn that ends, or the watch coming back, makes its hidden page due again (a busy page
    /// has no deadline).
    func followTurns(_ turns: AgentTurnStateStore) { pages.followTurns(turns) }

    // The planner's surface, as the App and the tests call it.
    var hasDeadline: Bool { pages.hasDeadline }
    var frozen: Set<String> { pages.frozen }
    func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) { pages.update(setting: setting, pressure: pressure) }
    func sync(_ changed: Set<String>? = nil, _ isRendering: (String) -> Bool) {
        let changed = changed.map { ids in
            let pages = hibernationPages() ?? [:]
            return Set(pages.keys.filter { ids.contains(AgentTabKey(relaunchStorageKey: $0).key) })
        }
        pages.sync(changed) { let scoped = AgentTabKey(relaunchStorageKey: $0); return !scoped.machine.isEmpty || isRendering(scoped.key) } // the cache keys renderers by tab id: a page whose id two machines share stays awake
    }
    func replan() { pages.replan() }
    func keepsPage(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? { pages.keepsPage(key, onScreen: onScreen) }
    func keepsAwake(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? { pages.keepsAwake(key, onScreen: onScreen) }

    // MARK: HiddenChatPagesHost

    func hibernationPages() -> [String: AgentPaneView]? {
        guard let tabs = store() else { return nil }
        let duplicates = AgentTabMap<AgentPaneView>.duplicateIDs(tabs.views.entries.map(\.key))
        return tabs.views.entries.reduce(into: [:]) { $0[$1.key.relaunchStorageKey(duplicateIDs: duplicates)] = $1.value }
    }
    func hibernationPage(_ key: String) -> AgentPaneView? {
        guard let tabs = store() else { return nil }
        let scoped = scopedKey(key, in: tabs)
        return tabs.existingView(scoped.key, machine: scoped.machine)
    }
    func pageDraws(_ key: String) -> Bool { !AgentTabKey(relaunchStorageKey: key).machine.isEmpty || (store().map { isRendering(scopedKey(key, in: $0).key) } ?? true) }
    func pageClock() -> ContinuousClock.Instant { now() }
    func pagePinned(_ key: String) -> Bool { isPinned(key) }
    func pageTurnsKnown() -> Bool { turnsWatched() }
    func pageTurnBusy(_ key: String) -> Bool { chat(key).map { AgentTurnState.isWorking(turns.state(for: $0), detail: turns.detail(for: $0)) } ?? false }
    func pageArchived(_ key: String) -> Bool { chat(key).flatMap(turns.detail(for:))?.archived == true }
    func freezeControl(of page: AgentPaneView) -> (any BrowserFreezing)? { freezer(page) }
    func setFrozen(_ control: any BrowserFreezing, _ frozen: Bool) -> Bool { control.setFrozen(frozen) }
    func setPageWork(_ page: AgentPaneView, _ work: (@MainActor () -> Void)?) { page.model.transport.beforePageWork = work }
    func dropReleasedFrame(_ key: String) { if let tabs = store() { let scoped = scopedKey(key, in: tabs); tabs.launchImages.drop(tabs.launchImages.slot(scoped.key, machine: scoped.machine)) } }

    func pageIsUntouchedNewTab(_ key: String) -> Bool {
        guard let tabs = store() else { return false }
        let scoped = scopedKey(key, in: tabs)
        guard let view = tabs.existingView(scoped.key, machine: scoped.machine), view.isUntouchedNewTab, tabs.sessions[scoped] == nil,
              let (record, _) = tabs.record(for: tabs.resolvedKey(scoped)), record.session == nil,
              tabs.hostKind(record, listedHere: true) == .local,
              tabs.daemon(for: tabs.resolvedKey(scoped))?.isLocal != false else { return false }
        return tabs.remoteSeeds[scoped] == nil && tabs.remoteCreations[scoped] == nil && tabs.remoteStarts[scoped] == nil
    }

    /// A chat of this Mac's acpmux with a session, off screen, not a New Tab page, and no shell
    /// command run in it.
    func pageMayRelease(_ key: String, onScreen: Bool) -> Bool {
        guard let tabs = store() else { return false }
        let scoped = scopedKey(key, in: tabs)
        let resolved = tabs.resolvedKey(scoped)
        if pages.newTabIsExcess(key), pageIsUntouchedNewTab(key), let view = tabs.views[resolved] {
            return !(onScreen && AgentPaneHibernationCapture(view: view).isOnScreen)
        }
        // A crashed page keeps its notice: a rebuild would reload it without the person's Reload.
        guard let view = tabs.views[resolved], !view.showsCrashNotice, !(onScreen && AgentPaneHibernationCapture(view: view).isOnScreen), view.model.newTab == nil, !view.model.shell.hasRuns,
              tabs.newTabPages[resolved] == nil, let (record, _) = tabs.record(for: resolved),
              tabs.hostKind(record, listedHere: true) == .local,
              tabs.daemon(for: resolved)?.isLocal != false else { return false }
        return (tabs.sessions[resolved] ?? view.model.sessionId ?? record.session) != nil
            && tabs.remoteSeeds[resolved] == nil && tabs.remoteCreations[resolved] == nil && tabs.remoteStarts[resolved] == nil
    }

    /// A page in Chromium (or still making its browser), not a crashed or New Tab page, not a Chief chat.
    func pageMayFreeze(_ key: String, onScreen: Bool) -> Bool {
        guard let tabs = store() else { return false }
        let scoped = scopedKey(key, in: tabs)
        let stored = tabs.resolvedKey(scoped)
        guard let view = tabs.existingView(stored.key, machine: stored.machine), freezer(view) != nil || waitsForFreezer(view) else { return false }
        // A crashed page keeps its notice; a New Tab page follows its own parking (the spare pool).
        if view.showsCrashNotice || view.model.newTab != nil || tabs.newTabPages[stored] != nil { return false }
        // The Chief's own chats stay as they are.
        if let (record, _) = tabs.record(for: stored),
           tabs.hostKind(record, listedHere: true) == .chief {
            return false
        }
        return !(onScreen && AgentPaneHibernationCapture(view: view).isOnScreen)
    }

    /// Keeps the page's frame and what it holds that acpmux does not, then lets the page go if it
    /// is still the same hidden page.
    func releasePage(_ key: String) {
        guard let tabs = store(), let view = hibernationPage(key), let started = pages.beginRelease(key) else { return }
        let tabID = { let scoped = scopedKey(key, in: tabs); return tabs.launchImages.slot(scoped.key, machine: scoped.machine) }()
        let readWake = wakeState
        let takeSnapshot = snapshot
        let cause = started.cause
        Task { @MainActor [weak self] in
            let captured = await AgentPaneHibernationCapture(view: view).capture(key: tabID, images: tabs.launchImages, requiresFrame: started.requiresFrame, wake: readWake, snapshot: takeSnapshot)
            guard let self else { return }
            pages.endRelease(key)
            if let reason = captured.kept {
                logger.info("agent page \(key, privacy: .public) kept: \(reason, privacy: .public)")
                return pages.keptForNow(key)
            }
            let wake = captured.wake
            // Recheck the exact page, visibility and turn after every capture/encoding await.
            guard pages.isDue(key, page: view) else {
                tabs.launchImages.drop(tabID)
                return replan()
            }
            letGo(key, page: view, wake: wake, in: tabs, cause: cause)
        }
    }

    /// Tab `key`'s captured page goes: its pane lets go of it, the tab keeps its session and `wake`, and the
    /// next show builds the page again.
    private func letGo(_ key: String, page view: AgentPaneView, wake: AgentPaneWakeState?, in tabs: AgentTabStore, cause: String) {
        let storageScoped = AgentTabKey(relaunchStorageKey: key)
        if storageScoped.machine.isEmpty { displace(storageScoped.key) }
        // The tab keeps its session and every other state: the next show builds the page again.
        let scoped = tabs.views.entries.first(where: { $0.value === view })?.key ?? storageScoped
        let stored = tabs.resolvedKey(scoped)
        if let session = view.model.sessionId { tabs.sessions[stored] = session }
        tabs.wakeStates[stored] = wake.flatMap { $0.isEmpty ? nil : $0 }
        tabs.views[stored] = nil
        tabs.retirer.retire(view)
        tabs.stopCustomizationWhenUnused()
        pages.released(key)
        packing?.schedule() // the release may have made room in an older renderer
        // Notice, not info: the field log keeps it (the page is built again when shown).
        logger.notice("released agent page \(key, privacy: .public) cause=\(cause, privacy: .public); it is built again when shown")
    }

    // MARK: Chat renderer recycle (``startRendererRecycle(services:)``)

    /// Why tab `key`'s page keeps the chat renderer, shown or not, or nil when it can go now: the hidden-page
    /// policy without its on-screen clause (this Mac's chat with a session, no shell run, no crash notice, its
    /// turn known and idle, not pinned or paired), not archived in flight, and no release of it running.
    func recycleExemption(_ key: String) -> String? {
        if let exemption = keepsPage(key, onScreen: false) { return exemption.rawValue }
        if pageArchived(key) { return "archived" }
        return pages.releaseRuns(key) ? "a release runs" : nil
    }

    /// Captures tab `key`'s page for the recycle, as a release does but with no first frame required: its wake
    /// state, its frame when `frame` (the shown chats; a hidden Chromium page is never captured), and why it stays
    /// (unsaved sends, no answer). Nil when there is no page or a release of it runs.
    func captureForRecycle(_ key: String, frame: Bool) async -> (page: AgentPaneView, wake: AgentPaneWakeState?, frame: CGImage?, size: NSSize, kept: String?)? {
        guard let tabs = store(), let view = hibernationPage(key), pages.beginRelease(key) != nil else { return nil }
        let tabID = { let scoped = scopedKey(key, in: tabs); return tabs.launchImages.slot(scoped.key, machine: scoped.machine) }()
        let takeSnapshot = snapshot
        var taken: (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?
        let captured = await AgentPaneHibernationCapture(view: view).capture(key: tabID, images: tabs.launchImages, requiresFrame: false, wake: wakeState) { page in
            guard frame else { return nil }
            taken = await takeSnapshot(page)
            return taken
        }
        pages.endRelease(key)
        return (view, captured.wake, taken?.image, taken?.size ?? .zero, captured.kept)
    }

    /// The recycle let tab `key`'s captured page go (it is still the tab's page): as a release does.
    func letGoForRecycle(_ key: String, page view: AgentPaneView, wake: AgentPaneWakeState?) -> Bool {
        guard let tabs = store(), hibernationPage(key) === view else { return false }
        letGo(key, page: view, wake: wake, in: tabs, cause: "renderer-recycle")
        return true
    }

}

extension AgentPageHibernation: RendererPackingHost {
    func packingMayMove(_ key: String, _ page: AgentPaneView) -> Bool {
        guard AgentTabKey(relaunchStorageKey: key).machine.isEmpty, page.pageDrawsOverCovers, page.model.hasPainted,
              AgentPaneHibernationCapture(view: page).isOnScreen, pageTurnsKnown(), !pageTurnBusy(key) else { return false }
        return pageMayRelease(key, onScreen: false)
    }
    func packingBrowser(_ page: AgentPaneView) -> Int32? { browserID(page) }
    func packingLivePages() -> [RendererPacking.LivePage] { livePages() }
    /// The release's steps on a shown page: its picture is taken by hand (a visible Chromium page captures safely).
    func packingRebuild(_ key: String, _ page: AgentPaneView, stillIdle: @escaping @MainActor () -> Bool) async -> String? {
        guard let tabs = store() else { return "no agent tabs" }
        let scoped = scopedKey(key, in: tabs)
        let slot = tabs.launchImages.slot(scoped.key, machine: scoped.machine)
        let wake = await wakeState(page)
        if let kept = AgentPaneWakeState.keepReason(wake, hasHandshake: page.model.hasHandshake) { return kept }
        guard let frame = await snapshot(page), await tabs.launchImages.hold(slot, frame.image, size: frame.size, appearance: frame.appearance) else { return "no frame" }
        guard let stored = tabs.views.entries.first(where: { $0.value === page }).map({ tabs.resolvedKey($0.key) }), stillIdle() else {
            tabs.launchImages.drop(slot)
            return "in use"
        }
        if let session = page.model.sessionId { tabs.sessions[stored] = session }
        tabs.wakeStates[stored] = wake.flatMap { $0.isEmpty ? nil : $0 }
        guard reshow(scoped.key, { tabs.views[stored] = nil; tabs.retirer.retire(page) }) else {
            tabs.wakeStates[stored] = nil
            tabs.launchImages.drop(slot)
            return "no pane shows it"
        }
        return nil
    }
}

extension AgentPageHibernation {
    /// The App's side of ``CEFChatRendererRecycle``: after each renderer check (`CEFPageRendererGC`), a chat renderer
    /// past its bound whose pages are all spares or idle chats, while the person is away, is emptied and its shown
    /// chats are built again in a fresh process.
    ///
    /// 1. Every chat in it is captured as a hidden idle chat's release captures it (``AgentPageHibernation``), with
    ///    no first frame required; the shown chats keep their frame. Any page kept (unsaved sends, no answer) ends it.
    /// 2. In one main-actor turn the spare pool holds empty, the next Cmd-N's reservation pauses and its page goes,
    ///    the closed chats kept for Reopen Closed are torn down, and every chat lets go of its page (its tab keeps its
    ///    session and wake state). The shown panes draw the chat's frame meanwhile.
    /// 3. Once the old renderer exited (at most ``AgentPageRetirer/delay`` plus ``CEFChatRendererRecycle/exitLimit``),
    ///    each pane still selecting its chat shows it again through the normal show path, and the pools refill.
    /// 4. ``recycleSettleDelay`` later one notice in `app.hibernation` gives the resident size before and after.
    ///
    /// Started only when `CMUX_NEXT_CHAT_RENDERER_RECYCLE=1` (``AppServices/startHibernation(settings:)``).
    func startRendererRecycle(services: AppServices) {
        recycleServices = services
        services.cache.cef.afterPageRendererChecks { [weak self] in await self?.checkChatRenderer() }
    }

    /// How long after the rebuild the fresh renderer's resident size is read (the bench's chats draw within 2 s).
    static let recycleSettleDelay: Duration = .seconds(10)

    /// One renderer check ended: recycles the first chat renderer that is due and may go.
    func checkChatRenderer() async {
        guard !recycleRunning, let services = recycleServices, let tabs = services.madeAgentTabs else { return }
        let agentPages = self
        let cef = services.cache.cef
        let all = cef.rendererPages
        let chatRenderers = Set(all.filter { $0.origin == CEFChatRendererRecycle.chatOrigin }.compactMap(\.rendererClients.first))
        guard !chatRenderers.isEmpty else { return }
        recycleRunning = true
        defer { recycleRunning = false }
        for renderer in chatRenderers.sorted() {
            guard let sample = await ChromiumHelperProcess.renderer(client: renderer),
                  recycleState.isDue(renderer: renderer, resident: sample.resident, now: .now, live: chatRenderers) else { continue }
            let pages = cef.rendererPages.filter { $0.rendererClients.first == renderer }
            switch CEFChatRendererRecycle.decide(recycleClassify(pages, tabs: tabs, agentPages: agentPages), personIdle: recyclePersonIdle, shuttingDown: recycleShuttingDown) {
            case .skip(let why):
                logger.info("chat renderer \(renderer) at \(sample.resident >> 20) MB not recycled: \(why, privacy: .public)")
            case .recycle(let release, let show):
                await recycleRenderer(renderer: renderer, pid: sample.pid, before: sample.resident, release: release, show: show, tabs: tabs, agentPages: agentPages)
            }
            return
        }
    }

    private var recyclePersonIdle: Bool {
        CEFChatRendererRecycle.personIdle(secondsSinceInput: recycleInput.secondsSinceLastInput(), appActive: NSApp.isActive)
    }

    private var recycleShuttingDown: Bool { recycleServices?.quit.isQuitting != false || recycleServices?.cache.cef.isShuttingDown != false }

    /// What each page of the renderer is to the recycle, by browser id.
    private func recycleClassify(_ pages: [CEFRendererPage], tabs: AgentTabStore, agentPages: AgentPageHibernation) -> [CEFChatRendererRecycle.Page] {
        guard let services = recycleServices else { return [] }
        let duplicates = AgentTabMap<AgentPaneView>.duplicateIDs(tabs.views.entries.map(\.key))
        var byBrowser: [Int32: CEFChatRendererRecycle.Page] = [:]
        for (key, view) in tabs.views.entries {
            guard let browser = Self.recycleBrowserID(of: view) else { continue }
            let storage = key.relaunchStorageKey(duplicateIDs: duplicates)
            let newTab = view.model.newTab != nil || tabs.newTabPages[key] != nil
            let reserved = tabs.tabStores[key] === services.daemon.store && tabs.tabStores[key]?.reservedWorkspace?.tabKey == key.key && view.isUntouchedNewTab
            byBrowser[browser] = CEFChatRendererRecycle.tabPage(
                key: storage, newTab: newTab, reservedUntouched: reserved,
                exemption: newTab ? nil : agentPages.recycleExemption(storage), shown: AgentPaneHibernationCapture(view: view).isOnScreen)
        }
        for view in services.newTabSpares.spares + tabs.retirer.keptPages.map({ $0.view }) {
            if let browser = Self.recycleBrowserID(of: view) { byBrowser[browser] = .spare }
        }
        return pages.map { page in
            if page.origin != CEFChatRendererRecycle.chatOrigin { return .keeps("a page of \(page.origin)") }
            return byBrowser[page.browserID] ?? .keeps("a page no tab or pool holds")
        }
    }

    private static func recycleBrowserID(of view: AgentPaneView) -> Int32? { (view.chromiumPage as? CEFPageChromiumPage)?.tab.browserID }

    private func recycleRenderer(renderer: Int32, pid: Int32, before: Int, release: [String], show: [String],
                         tabs: AgentTabStore, agentPages: AgentPageHibernation) async {
        // 1. Capture every chat; one kept ends the recycle.
        var captured: [(key: String, page: AgentPaneView, wake: AgentPaneWakeState?, frame: CGImage?, size: NSSize)] = []
        var kept: String?
        for key in release {
            guard let capture = await agentPages.captureForRecycle(key, frame: show.contains(key)) else { kept = "\(key) went"; break }
            captured.append((key, capture.page, capture.wake, capture.frame, capture.size))
            if let reason = capture.kept { kept = "\(key) kept: \(reason)"; break }
            // A shown chat with no frame would leave its pane empty until the rebuild.
            if show.contains(key), capture.frame == nil { kept = "\(key) has no frame"; break }
        }
        // The captures awaited: everything is read again.
        if kept == nil, !recyclePersonIdle { kept = "the person came back" }
        if kept == nil, recycleShuttingDown { kept = "shutting down" }
        if kept == nil, let moved = captured.first(where: { agentPages.hibernationPage($0.key) !== $0.page || agentPages.recycleExemption($0.key) != nil }) { kept = "\(moved.key) changed" }
        guard kept == nil, let services = recycleServices else {
            for capture in captured { agentPages.dropReleasedFrame(capture.key) }
            agentPages.replan() // the captures thawed them
            recycleState.aborted(at: .now)
            return logger.info("chat renderer \(renderer) at \(before >> 20) MB not recycled: \(kept ?? "", privacy: .public)")
        }

        // 2. One turn: nothing makes a page in the old renderer, and every page in it goes.
        let panes: [(tab: String, pane: PaneController, frame: CGImage?, size: NSSize)] = captured.compactMap { capture in
            let tab = AgentTabKey(relaunchStorageKey: capture.key).key
            guard show.contains(capture.key), let pane = services.cache.presenter(of: tab) as? PaneController else { return nil }
            return (tab, pane, capture.frame, capture.size)
        }
        let store = services.daemon.store
        let wasPaused = store.reservationPaused
        services.newTabSpares.holdEmpty()
        store.reservationPaused = true
        services.windows.controllers.forEach { $0.reservedContent.drop() }
        tabs.releaseReservedWorkspace(on: store, .recycle)
        tabs.retirer.dropKept()
        var released = 0
        for capture in captured where agentPages.letGoForRecycle(capture.key, page: capture.page, wake: capture.wake) { released += 1 }
        for shown in panes where shown.pane.currentTabKey == nil {
            shown.pane.leftEmptyByMove = false // a first visit during the wait would build the page in the old renderer
            guard let frame = shown.frame else { continue }
            shown.pane.view.showLaunchImage(NSImage(cgImage: frame, size: shown.size))
            shown.pane.view.launchImageMayClear = { false } // the rebuild's own frame replaces it
        }

        // 3. The old renderer exits once its last page closed (the retirer closes them after its delay).
        let exited = await ChromiumHelperProcess.waitForExit(pid, limit: AgentPageRetirer.delay + CEFChatRendererRecycle.exitLimit)
        for shown in panes where shown.pane.currentTabKey == nil {
            if shown.pane.stripModel.selectedID?.rawValue == shown.tab, !recycleShuttingDown {
                services.presentation.showNow(shown.pane)
            } else {
                shown.pane.view.clearLaunchImage()
            }
        }
        services.newTabSpares.endHold()
        store.reservationPaused = wasPaused
        if !wasPaused { services.windows.controllers.forEach { $0.reservedContent.fill() } }
        recycleState.recycled(at: .now)

        // 4. The fresh renderer's size once its chats drew.
        let shownCount = panes.count
        recycleSettle.schedule(after: Self.recycleSettleDelay) { @MainActor [weak self] in
            await self?.recycleSettled(before: before, released: released, shown: shownCount, exited: exited)
        }
    }

    private func recycleSettled(before: Int, released: Int, shown: Int, exited: Bool) async {
        guard let cef = recycleServices?.cache.cef,
              let renderer = cef.rendererPages.first(where: { $0.origin == CEFChatRendererRecycle.chatOrigin })?.rendererClients.first,
              let sample = await ChromiumHelperProcess.renderer(client: renderer) else {
            return logger.notice("chat renderer recycled before=\(before >> 20) MB after=none released=\(released) shown=\(shown) exited=\(exited)")
        }
        recycleState.settled(renderer: renderer, resident: sample.resident)
        logger.notice("chat renderer recycled before=\(before >> 20) MB after=\(sample.resident >> 20) MB released=\(released) shown=\(shown) exited=\(exited)")
    }
}
