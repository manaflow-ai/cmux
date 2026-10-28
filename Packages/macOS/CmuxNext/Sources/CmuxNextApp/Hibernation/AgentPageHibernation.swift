import AppKit
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Lets hidden agent chat pages go (cx-x15rz). Each chat tab's page is a web view with its own
/// web content process (about 75 MB), and before this it stayed until the tab closed. A chat
/// hidden past the browser pages' threshold (`browser.hibernation` and memory pressure, as
/// `HibernationPlanner` sets it) lets its page go; its tab keeps its session, so showing it again
/// builds the page on the same chat (``AgentTabStore/view(for:)``), which acpmux replays with its
/// draft. Its last frame is drawn under the pane until the new page paints.
///
/// A page stays when its tab is pinned (unless the setting includes pinned tabs), its chat's
/// turn runs or waits on the person (acpmux's turn state, `AgentTurnStateStore`), it is a New
/// Tab page or another machine's chat, or a shell command ran in it (closing the page ends the
/// command or drops its output). A page waits at
/// least ``minimumHidden`` even under critical pressure, so the composer's last keystrokes reach
/// acpmux. Events only, no polling: a page hides or shows (`TabContentCache`'s presentation
/// changes), the setting or the pressure changes, and one deadline for the next page to come due.
///
/// Live hidden pages are also held to the Mac's budget (``liveHiddenLimit``,
/// `SubsystemBudget.liveHiddenAgentPages`, behind `memoryDiscardAgentPagesOverBudget`): past it the
/// least recently shown pages that may go are let go at once, before their timeout, each hidden at
/// least ``minimumHidden``. Every live hidden page counts, the ones that stay too (a busy chat), as
/// Chrome's `FrameEvictionManager` counts every saved frame and culls the least recently used
/// unlocked ones (`components/viz/client/frame_eviction_manager.cc`, `CullUnlockedFrames`).
///
/// With `pageLifecycle` on the page lifecycle drives agent chats and New Tab pages
/// instead (``follow(_:)``): its planner freezes and discards them with every exemption above as a keep
/// reason (a running turn blocks both: acpmux cannot resync a frozen page's stream yet), this class
/// performs the discard, and its own timeout and budget stay off. An untouched New Tab page has no reason
/// to stay and goes at the planner's 300 s, as Chrome discards a background New Tab page like any tab;
/// one whose chip pick started a chat, typed text or attachments keeps a draft.
@MainActor
final class AgentPageHibernation {
    static let minimumHidden: Double = 10
    /// How soon a due page still in its window is first looked at again.
    static let onScreenRecheck: Double = 1

    /// The agent tab store once the App made it (no agent tab yet: nothing to release).
    let store: () -> AgentTabStore?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private(set) var setting: BrowserHibernationSetting = .fallback
    private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page was last visible.
    var hiddenAt: [String: ContinuousClock.Instant] = [:]
    var shown: Set<String> = []
    var releasing: Set<String> = []
    /// The next page to come due: one background deadline (nobody sees a page let go).
    let deadline: MainDeadline
    /// Where the turn follow runs (``followTurns(_:)``): the app's one main-thread scheduler.
    let mainWork: MainWorkScheduler
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
    /// Reports to the discard planner's last inputs (`debug.discards`): the app's `BrowserHibernation.discards`.
    var noteDiscard: (ContentDiscardReport.Event) -> Void = { _ in }
    private(set) var releasedCount = 0
    /// A page was let go (the App counts it in the memory histograms).
    var onRelease: () -> Void = {}
    /// A page is due later and the timer for it runs (tests).
    var hasDeadline: Bool { deadline.isScheduled }
    /// How soon the armed deadline comes due, in seconds; nil when none is armed (tests tell the
    /// budget's short deadline from the timeout's).
    var deadlineDelay: Double?
    /// Follows the acpmux turns (``followTurns(_:)``): a background ``ServiceObservation`` (it replans pages while
    /// no window shows).
    private var turnObservation: ServiceObservation<(UInt64, Bool)>?
    /// The page lifecycle that drives agent pages (``follow(_:)``); nil: this class's timeout and budget.
    private(set) weak var lifecycle: PageLifecycle?
    /// What an agent page held as it hid, read while it still ran: a frozen page cannot answer, so its
    /// discard asks it nothing (as `WebContents::Discard` asks the renderer nothing).
    struct HideRead {
        /// This read among the hides; an answer for an older one is dropped.
        let generation: Int
        /// The appearance the page drew its hide picture in: its tab's launch image shows only in that one.
        let appearance: NSAppearance.Name?
        /// The read ended; ``wake`` is the page's answer, nil when it did not answer in time.
        var isDone = false
        /// What the page held that acpmux does not (attachments, shell text, scroll), handed to its rebuild.
        var wake: AgentPaneWakeState?
        /// The page runs (it is not frozen): only a running page can answer a read.
        var runs = true
        /// Reads in a row the connected page did not answer (``hideReadRetries``).
        var unanswered = 0
    }
    /// How many times in a row a connected page that does not answer its hide read is asked again at
    /// once. Past that it is asked again when it runs after a freeze or its chat's turn changes.
    static let hideReadRetries = 2
    /// Each hidden agent page's ``HideRead``, by tab (lifecycle mode only).
    private(set) var hideReads: [String: HideRead] = [:]
    private var hideCount = 0
    /// The reasons an agent page's view reports itself (loading, focus, its document's keepAlive and the
    /// host's holds); tests whose page never loads pass none.
    var pageFacts: @MainActor (PageWebViewLifecycle) -> Set<PageLifecyclePlanner.KeepReason> = { $0.lifecycleKeepReasons }
    /// Encodes a hiding page's picture, its tab's launch image once it is let go (tests keep none).
    var snapshotEncoder = PageSnapshotEncoder { _, done in done(nil) }
    /// The most hidden pages kept live; nil: only the timeout lets pages go.
    var liveHiddenLimit: Int? {
        didSet { if liveHiddenLimit != oldValue { replan() } }
    }
    /// The app's one urgent pass over tabs, chats and pages takes the critical memory event's discard
    /// (feature `memoryUrgentDiscardRanking`, set by the browser hibernation): at critical pressure the
    /// timeout then lets one chat go per urgent pace interval, and none until one interval after the
    /// pressure turns critical and after each urgent pass (``urgentPassDidRun()``).
    var leavesCriticalEventToUrgentPass = false
    /// Until when the timeout lets no chat go (``leavesCriticalEventToUrgentPass``).
    var noReleaseBefore: ContinuousClock.Instant?

    /// - Parameters:
    ///   - tabs: The agent tab store once the App made it.
    ///   - deadlines: The app's main-thread deadline scheduler: the next page's deadline is a background deadline
    ///     on it, and the turn follow runs on its scheduler.
    init(tabs: @escaping () -> AgentTabStore?, deadlines: MainDeadlineScheduler) {
        store = tabs
        deadline = MainDeadline(owner: "AgentPageHibernation", workClass: .background, scheduler: deadlines)
        mainWork = deadlines.work
    }

    /// Wired to the App: never makes the agent tab store (that starts acpmux), follows the panes'
    /// presentation changes, and lets the pane holding a released page go.
    convenience init(services: AppServices) {
        self.init(tabs: { [weak services] in services?.madeAgentTabs }, deadlines: services.mainDeadlines)
        // R-index: the machines' tab index, O(1) per key.
        isPinned = { [weak machines = services.machines] key in machines?.tabIndex.locate(key)?.0.pinned ?? false }
        turnState = { [weak services] key in
            guard let tabs = services?.madeAgentTabs, var (record, _) = tabs.lookup(tabs.resolve(key)) else { return nil }
            // The session the page runs, as its rebuild uses it: a refused bind leaves the record on the old one.
            record.session = tabs.existingView(key)?.model.sessionId ?? tabs.session(of: key)
            return AgentTurnStateStore.shared.state(for: record)
        }
        // A run without the watch (showcase, the mock pane) has no turns to wait for.
        turnsWatched = { AgentTurnStateFeed.shared == nil || AgentTurnStateStore.shared.watching }
        displace = { [weak services] key in services?.cache.presenter(of: key)?.surfaceWasDisplaced(key) }
        followTurns(AgentTurnStateStore.shared)
        let cache = services.cache
        noteDiscard = { [weak cache] event in cache?.hibernation?.noteDiscard(event) }
        // `pageLifecycle`: agent tabs' reveal and conceal reach the page lifecycle. A chat shown before
        // this (the launch's) waits for its mount, which its live page answers now.
        if let lifecycle = cache.pageLifecycle {
            snapshotEncoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
            follow(lifecycle)
            for key in (services.madeAgentTabs?.views ?? [:]).keys where cache.pendingMounts[key] != nil {
                cache.ledger.setRetained(key, false) // its memory is the lifecycle's, as a page tab's
                cache.contentDidMount(key)
            }
            return
        }
        if services.features.isEnabled(.memoryDiscardAgentPagesOverBudget) {
            liveHiddenLimit = SubsystemBudget.forThisMac(gpuResidentAvailable: false).liveHiddenAgentPages
        }
        cache.presentationChanges.subscribe("agent-page-hibernation") { [weak self, weak cache] in
            guard let cache else { return }
            self?.sync(cache.presentationChanges.changedKeys) { cache.isRendering($0) }
        }
    }

    /// From now on `lifecycle` freezes and discards agent pages: an agent tab's reveal and conceal reach
    /// it as a page tab's do (``AgentPageLifecycleTarget``), this class gives it each page's keep reasons
    /// and performs its discard, and keeps no timeout and no budget of its own.
    func follow(_ lifecycle: PageLifecycle) {
        self.lifecycle = lifecycle
        (liveHiddenLimit, deadlineDelay) = (nil, nil)
        deadline.cancel()
        let pages = lifecycle.pageOfTab
        lifecycle.pageOfTab = { [weak self] key in pages(key) ?? self?.lifecycleTarget(key) }
    }

    /// Tab `key`'s live agent page; nil for a tab with none (not an agent tab, or one let go).
    private func lifecycleTarget(_ key: String) -> (any PageLifecycleTarget)? {
        store()?.existingView(key).map { AgentPageLifecycleTarget(key: key, pane: $0, owner: self) }
    }

    /// A turn that ends, or the watch coming back, makes its hidden page due again (a busy page
    /// has no deadline): a background ``ServiceObservation``, applied now and once per change.
    func followTurns(_ turns: AgentTurnStateStore) {
        turnObservation?.cancel()
        turnObservation = ServiceObservation(.background, owner: "AgentPageHibernation.turns", on: mainWork) {
            (turns.stateRevision, turns.watching)
        } apply: { [weak self] _ in
            guard let self else { return }
            if lifecycle == nil { replan() } else { refreshTurnReasons() }
        }
    }

    func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) {
        guard setting != self.setting || pressure != self.pressure else { return }
        if pressure == .critical, self.pressure != .critical, leavesCriticalEventToUrgentPass { holdReleases() }
        if pressure != .critical { noReleaseBefore = nil }
        (self.setting, self.pressure) = (setting, pressure)
        replan()
    }

    /// Compares every page with whether its tab draws now, and reports the ones that changed.
    /// Whether the tab draws, not whether its view is still in a window: presentation changes
    /// come before the pane swaps its content, so the outgoing page is still on screen then.
    /// (A release checks the window again.)
    /// `changed`: the tabs this change is about (nil: every page), so a switch is O(changed tabs).
    func sync(_ changed: Set<String>? = nil, _ isRendering: (String) -> Bool) {
        guard let tabs = store() else { return }
        for key in changed ?? Set(tabs.views.keys) where tabs.existingView(key) != nil {
            let visible = isRendering(key)
            if visible != shown.contains(key) { pageVisibility(key, visible: visible) }
        }
    }

    /// Tab `key`'s page started or stopped drawing.
    func pageVisibility(_ key: String, visible: Bool) {
        guard let tabs = store() else { return }
        if visible {
            shown.insert(key)
            hiddenAt[key] = nil
            tabs.launchImages.drop(key)
            noteDiscard(.shown(key, .agentPage))
        } else if tabs.existingView(key) != nil {
            shown.remove(key)
            hiddenAt[key] = now()
            noteDiscard(.hidden(key, .agentPage))
            replan()
        }
    }

    func forget(_ key: String) {
        shown.remove(key)
        hiddenAt[key] = nil
        hideReads[key] = nil
        store()?.launchImages.drop(key)
        noteDiscard(.removed(key))
    }

    /// Asks `view` what it holds that acpmux does not and, with `frame`, for its last frame; `then` gets
    /// both. The one read of a page that may go: the timeout's release and the lifecycle's hide.
    func read(_ view: AgentPaneView, frame withFrame: Bool,
              then: @escaping @MainActor (AgentPaneWakeState?, (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?) async -> Void) {
        let readWake = wakeState
        // task-owner: one read, bounded by the wake state's 3 s and the frame's 2 s deadlines
        // main-hop-allow: the wake state and the frame are the agent page's main-actor async script reads, and `then` (main-actor async: it awaits the launch image's encode) runs in their resume
        Task { @MainActor [weak self] in
            let wake = await readWake(view)
            var frame: (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?
            if withFrame { frame = await Self.frame(view) }
            guard self != nil else { return }
            await then(wake, frame)
        }
    }

    /// Keeps the page's frame and what it holds that acpmux does not, then lets the page go if it
    /// is still the same hidden page.
    func release(_ key: String) {
        guard let tabs = store(), let view = tabs.existingView(key), releasing.insert(key).inserted else { return }
        read(view, frame: true) { [weak self] wake, frame in
            guard let self else { return }
            releasing.remove(key)
            // A connected page that did not say what it holds (a large attachment still encoding)
            // stays: letting it go would drop its chips. The next plan asks again.
            if wake == nil, view.model.hasHandshake {
                logger.info("agent page \(key, privacy: .public) kept: no wake state in time")
                if let at = hiddenAt[key] { noteDiscard(.planned(key, .agentPage, hiddenFor: (now() - at).seconds, DiscardEligibility(keptFor: .unanswered))) }
                return
            }
            // The page may have shown, changed or got busy (a turn started) while it was asked
            // for its frame or the frame was encoded: then it stays, and the next plan decides.
            guard isDue(key, view, in: tabs) else { return replan() }
            if let frame { await tabs.launchImages.hold(key, frame.image, size: frame.size, appearance: frame.appearance) }
            guard isDue(key, view, in: tabs) else {
                tabs.launchImages.drop(key)
                return replan()
            }
            letGo(key, view, wake: wake, in: tabs)
        }
    }

    /// Whether tab `key`'s hidden page is still `view` and may go now.
    func isDue(_ key: String, _ view: AgentPaneView, in tabs: AgentTabStore) -> Bool {
        hiddenAt[key] != nil && tabs.existingView(key) === view && keepsPage(key) == nil
    }

    /// Lets `view`, tab `key`'s hidden page, go. The tab keeps its session and every other state, and
    /// `wake`, what the page held that acpmux does not: the next show builds the page again.
    func letGo(_ key: String, _ view: AgentPaneView, wake: AgentPaneWakeState?, in tabs: AgentTabStore) {
        displace(key)
        let stored = tabs.resolve(key)
        if let session = view.model.sessionId { tabs.sessions[stored] = session }
        tabs.wakeStates[stored] = wake.flatMap { $0.isEmpty ? nil : $0 }
        tabs.views[stored] = nil
        view.retire(on: tabs.retirer, closed: false)
        tabs.stopCustomizationWhenUnused()
        hiddenAt[key] = nil
        releasedCount += 1
        onRelease()
        noteDiscard(.discarding(key, .agentPage, HibernationPlanner.discardReason(at: pressure)))
        noteDiscard(.discarded(key))
        logger.info("released agent page \(key, privacy: .public)")
    }
}

// The page lifecycle's side (`pageLifecycle`): keep reasons, the hide read and the discard.
extension AgentPageHibernation: AgentPageLifecycleOwner {
    /// Why tab `key`'s hidden page `pane` stays, as the planner's keep reasons, with the ones `page` reports.
    /// Read once per planner pass, and handed to the lifecycle when a turn or the hide read changes them.
    func keepReasons(_ key: String, pane: AgentPaneView, page: PageWebViewLifecycle) -> Set<PageLifecyclePlanner.KeepReason> {
        pageFacts(page).union(tabReasons(key, pane: pane))
    }

    /// The reasons the tab gives, not its page view: the ones ``refreshKeepReasons(_:)`` hands on.
    private func tabReasons(_ key: String, pane: AgentPaneView) -> Set<PageLifecyclePlanner.KeepReason> {
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        guard let tabs = store() else { return [.unrestorable] }
        let stored = tabs.resolve(key)
        if isPinned(key) { reasons.insert(.pinned) }
        // Closing the page ends the command or drops its output.
        if pane.model.shell.hasRuns { reasons.insert(.shellCommandRan) }
        if tabs.unsentDrafts.hasDraft(stored) || holdsUnsavedState(key, pane: pane) { reasons.insert(.draft) }
        guard let (record, _) = tabs.lookup(stored) else { return reasons.union([.unrestorable]) }
        switch AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost) {
        case .remote: reasons.insert(.remoteChat)
        case .chief: reasons.insert(.unrestorable) // a Chief home's chat is not rebuilt here, as before
        case .local:
            if tabs.daemonForTab(key)?.isLocal == false || tabs.remoteSeeds[stored] != nil
                || tabs.remoteCreations[stored] != nil || tabs.remoteStarts[stored] != nil {
                reasons.insert(.remoteChat)
            }
        }
        if (tabs.sessions[stored] ?? pane.model.sessionId ?? record.session) != nil {
            // No watch, no known turn: a chat that looks idle may be working.
            if !turnsWatched() {
                reasons.insert(.turnsUnknown)
            } else if let turn = turnState(key) {
                if turn == .working { reasons.insert(.turnRunning) }
                if turn == .needsInput { reasons.insert(.awaitingPerson) }
            }
        } else if pane.model.newTab == nil, tabs.newTabPages[stored] == nil {
            reasons.insert(.unrestorable) // a chat with no session yet: nothing would rebuild it
        }
        return reasons
    }

    /// Whether the composer holds attachments or a pick started a chat no prompt went to, or what the page
    /// holds that acpmux does not is unknown: its hide read still runs, or a connected page did not answer
    /// it yet (a large attachment still encoding). Letting it go would drop its chips or that chat.
    private func holdsUnsavedState(_ key: String, pane: AgentPaneView) -> Bool {
        guard let read = hideReads[key] else { return false }
        guard read.isDone, let wake = read.wake else { return !read.isDone || pane.model.hasHandshake }
        return wake.attachments?.isEmpty == false || wake.pendingChat == true
    }

    /// Reads what the page holds now, in the conceal turn, when it surely runs. Until the read ends the
    /// page counts as holding a draft, so no discard drops its chips.
    func pageDidHide(_ key: String, pane: AgentPaneView) {
        hideCount += 1
        hideReads[key] = HideRead(generation: hideCount, appearance: pane.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        readHidden(key, pane: pane)
        refreshKeepReasons(key)
    }

    /// Asks tab `key`'s hidden page what it holds. A connected page that does not answer is asked again at
    /// once while it runs, up to ``hideReadRetries`` times; after that, when it runs again after a freeze
    /// or its chat's turn changes (``readAgainIfUnanswered(_:)``). A timeout is never a lasting draft.
    private func readHidden(_ key: String, pane: AgentPaneView) {
        guard let generation = hideReads[key]?.generation else { return }
        hideReads[key]?.isDone = false
        read(pane, frame: false) { [weak self] wake, _ in
            guard let self, var hideRead = hideReads[key], hideRead.generation == generation else { return }
            hideRead.isDone = true
            hideRead.wake = wake
            hideRead.unanswered = wake == nil ? hideRead.unanswered + 1 : 0
            hideReads[key] = hideRead
            if hideRead.unanswered <= Self.hideReadRetries, asksAgain(key, pane: pane) { return readHidden(key, pane: pane) }
            refreshKeepReasons(key)
        }
    }

    /// The connected page `pane`, still tab `key`'s and running, ended its hide read with no answer.
    private func asksAgain(_ key: String, pane: AgentPaneView) -> Bool {
        guard let read = hideReads[key], read.isDone, read.wake == nil, read.runs else { return false }
        return pane.model.hasHandshake && store()?.existingView(key) === pane
    }

    /// Tab `key`'s hidden page runs again or its turn changed: if its hide read went unanswered, it
    /// is asked again, with a fresh run of retries.
    private func readAgainIfUnanswered(_ key: String) {
        guard let pane = store()?.existingView(key), asksAgain(key, pane: pane) else { return }
        hideReads[key]?.unanswered = 0
        readHidden(key, pane: pane)
    }

    /// What the hide read is out of date.
    func pageDidShow(_ key: String) {
        hideReads[key] = nil
    }

    /// A frozen page answers nothing: no read is asked of it until it thaws. One with nothing on its acpmux
    /// connection waiting for it closes the connection until the thaw.
    func pageDidFreeze(_ key: String) {
        hideReads[key]?.runs = false
        guard let pane = store()?.existingView(key) else { return }
        closeConnectionWhileFrozen(key, pane: pane, reasons: tabReasons(key, pane: pane))
    }

    /// Tab `key`'s frozen page `pane`, whose tab gives `reasons`, lets its acpmux connection go when nothing
    /// on it waits for the page: its thaw opens it again and reads the chat from the page's last event. A turn
    /// that runs or waits on the person, a turn watch that is down, another machine's or a Chief home's chat,
    /// and a page whose hide read did not say it holds no started chat (a chip pick's, which no prompt went
    /// to) keep the connection. Asked at the freeze and whenever a frozen page's reasons change.
    private func closeConnectionWhileFrozen(_ key: String, pane: AgentPaneView, reasons: Set<PageLifecyclePlanner.KeepReason>) {
        guard let read = hideReads[key], read.isDone, let wake = read.wake, wake.pendingChat != true,
              reasons.isDisjoint(with: Self.reasonsThatKeepTheConnection) else { return }
        pane.closeTransportWhileFrozen()
    }

    /// The tab reasons that keep a frozen page's acpmux connection (``closeConnectionWhileFrozen(_:pane:reasons:)``).
    static let reasonsThatKeepTheConnection: Set<PageLifecyclePlanner.KeepReason> =
        [.turnRunning, .awaitingPerson, .turnsUnknown, .remoteChat, .unrestorable]

    /// The hidden page runs again (a turn started on it): a read it left unanswered is asked again.
    func pageDidThaw(_ key: String) {
        guard hideReads[key]?.runs == false else { return }
        hideReads[key]?.runs = true
        readAgainIfUnanswered(key)
    }

    /// Lets the page go with what its hide read; its hide picture is drawn under the pane until the page
    /// built on its next show paints. Makes no call into the page.
    func discard(_ key: String, pane: AgentPaneView) {
        guard let tabs = store(), tabs.existingView(key) === pane else { return }
        let read = hideReads.removeValue(forKey: key)
        if let picture = pane.page.hideState.encoded {
            tabs.launchImages.hold(key, encoded: picture.data, size: pane.page.bounds.size, appearance: read?.appearance)
        }
        letGo(key, pane, wake: read?.wake, in: tabs)
    }

    /// Hands the lifecycle tab `key`'s keep reasons now: one that blocks a freeze thaws a frozen page in
    /// this turn (a turn started), one that ended arms a pass (the turn ended, the hide read answered).
    /// Never the page view's own (its load): those it reports itself, and a copy here would go stale.
    /// A page that stays frozen whose connection no longer has anything waiting for it (the person's
    /// question went away with no turn running) lets the connection go now.
    private func refreshKeepReasons(_ key: String) {
        guard let lifecycle, let pane = store()?.existingView(key) else { return }
        let reasons = tabReasons(key, pane: pane)
        lifecycle.setKeepReasons(reasons, for: key)
        if lifecycle.state(of: key) == .frozen { closeConnectionWhileFrozen(key, pane: pane, reasons: reasons) }
    }

    /// A turn started or ended, or the turn watch went down or came back: every hidden agent page's
    /// reasons again, and a hide read a running page left unanswered is asked again (a page busy with
    /// its turn may answer once the turn ends). O(hidden agent pages), once per turn change.
    func refreshTurnReasons() {
        for key in hideReads.keys {
            readAgainIfUnanswered(key)
            refreshKeepReasons(key)
        }
    }
}
