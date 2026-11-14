package import CmuxNextCompat
package import CmuxNextBridge
package import CmuxNextSettings
import os

/// What ``HiddenChatPages`` reads from the App and asks it to do: the App's `AgentPageHibernation`
/// conforms with one-line forwards to the agent tab store and its pages.
@MainActor
package protocol HiddenChatPagesHost: AnyObject {
    /// A chat tab's page (the App's view).
    associatedtype Page: AnyObject
    /// A page's freeze control (its Chromium tab).
    associatedtype FreezeControl

    /// Every tab's page by its stored key; nil while the App has made no agent tab store.
    func hibernationPages() -> [String: Page]?
    /// Tab `key`'s page, through the tab's aliases; nil when it has none.
    func hibernationPage(_ key: String) -> Page?
    /// Whether tab `key` draws now (`TabContentCache.isRendering`).
    func pageDraws(_ key: String) -> Bool
    /// The clock hidden times are measured on (tests set it).
    func pageClock() -> ContinuousClock.Instant
    /// The tab is pinned.
    func pagePinned(_ key: String) -> Bool
    /// The acpmux turn watch is up: without it no chat's turn is known.
    func pageTurnsKnown() -> Bool
    /// The chat is working (acpmux's facts): its turn runs or waits on the person (a permission or a
    /// question), or a subagent or background command it started still runs.
    func pageTurnBusy(_ key: String) -> Bool
    /// The chat is archived (acpmux's `archived` tag): its hidden page goes at once, when nothing keeps it.
    func pageArchived(_ key: String) -> Bool
    /// The App's own reasons a hidden page may be let go (this Mac's chat with a session, no New Tab page,
    /// no shell command run in it, a page that shows no crash notice); `onScreen` also asks it is out of its window.
    func pageMayRelease(_ key: String, onScreen: Bool) -> Bool
    /// A local untouched New Tab page whose context lives in the native tab store.
    func pageIsUntouchedNewTab(_ key: String) -> Bool
    /// The App's own reasons a hidden page may freeze (it has or waits for a freeze control, it is no New Tab
    /// page, Chief chat or crashed page); `onScreen` also asks it is out of its window.
    func pageMayFreeze(_ key: String, onScreen: Bool) -> Bool
    /// The page's freeze control; nil for a page that cannot freeze (WebKit), or whose browser is still made.
    func freezeControl(of page: Page) -> FreezeControl?
    /// Freezes or thaws through `control`; false when the engine refused.
    @discardableResult
    func setFrozen(_ control: FreezeControl, _ frozen: Bool) -> Bool
    /// Runs `work` right before anything reaches the page (a push, a script call, a picture); nil removes it.
    func setPageWork(_ page: Page, _ work: (@MainActor () -> Void)?)
    /// Lets tab `key`'s hidden page go (it keeps its frame and what it holds; ``beginRelease(_:)`` first).
    func releasePage(_ key: String)
    /// Tab `key` shows again or closed: the frame kept for its released page is not needed (none
    /// while there is no agent tab store).
    func dropReleasedFrame(_ key: String)
}

/// The hidden agent chat pages' clocks and what they decide (cx-x15rz): when a hidden page freezes,
/// thaws or is let go. The App performs it (`AgentPageHibernation`).
///
/// A chat that is not drawn and is proven idle gives back its page (Leo, 2026-11-14: "obviously if
/// something isn't drawn/is completely proven idle then dont bother taking memory... but if it's working
/// then you can try to optimize but thats it"; "archived chats (ok well THOSE should defo release ram)").
/// Always on, with no setting (Lawrence, #38022: a perf change lands on, the switch deleted):
/// - an archived chat's hidden page goes at once;
/// - another hidden chat's page goes once it has been hidden ``idleRelease`` seconds (``idleReleaseUnderWarning``
///   under warning memory pressure, ``minimumHidden`` under critical), or sooner when `browser.hibernation`
///   lets chats go sooner, or when its workspace hibernates; the least recently seen first.
///
/// Proven idle: the turn watch is up and the chat's turn neither runs nor waits on the person, and no
/// subagent or background command of it runs (``HiddenChatPagesHost/pageTurnBusy(_:)``). A working chat
/// keeps its page; so do a pinned tab (unless `browser.hibernation` includes pinned tabs) and what the App
/// keeps (``HiddenChatPagesHost/pageMayRelease(_:onScreen:)``). A page that says it holds what it cannot hand
/// back (an unsaved send or edit, prompts for a trust answer) stays and is asked again. The draft, chips,
/// shell text and scroll place are handed back to the page built when the chat shows again.
/// A page waits at least ``minimumHidden`` even under critical pressure, so the composer's last keystrokes
/// reach acpmux. Events only, no polling: a page hides or shows, a turn or the archive tag changes, the
/// setting or the pressure changes, and one deadline for the next page to come due. Untouched local New
/// Tabs beyond the shared warm-page cap go after `minimumHidden` seconds and follow `browser.hibernation`
/// alone, as browser tabs do.
///
/// Long before that, a hidden chat's Chromium page freezes after `browser.freezeHiddenTabs` seconds (30 by
/// default), as a hidden browser tab does: its renderer runs no script, timers or frames, and it keeps
/// everything it holds (2026-10-28 self-audit: a renderer of chat pages at 23-50 % CPU and 647 MB while the
/// person was away). It thaws when it shows, when its turn starts or waits on the person, when work reaches
/// it, and before it is released. A pinned tab (unless the setting includes pinned tabs) stays awake, and
/// so does what the App keeps (``HiddenChatPagesHost/pageMayFreeze(_:onScreen:)``).
@MainActor
package final class HiddenChatPages<Host: HiddenChatPagesHost> {
    /// A page hidden less than this is never let go, even under critical pressure.
    package static var minimumHidden: Double { 10 }
    /// How soon a due page still in its window is first looked at again.
    package static var onScreenRecheck: Double { 1 }
    /// How soon a due page its release kept (it held prompts, or said nothing in time) is asked again.
    package static var keptRecheck: Double { 15 }
    /// How long a hidden, idle chat keeps its page at normal memory pressure: a look at another tab and
    /// back keeps it (a rebuilt page costs ~100 ms to its first content), anything longer gives it back.
    package static var idleRelease: Double { 60 }
    /// The same under warning memory pressure.
    package static var idleReleaseUnderWarning: Double { 30 }
    /// This planner's idle wait at normal pressure, ``idleRelease`` (tests of the freeze alone set it past their clock).
    package var idleWait: Double = HiddenChatPages<Host>.idleRelease

    /// The App's side; it owns this planner (weak: no cycle).
    private weak var host: Host?
    private var turnObservation: Task<Void, Never>?
    /// The turn store `followTurns` follows, and the pages whose turns it observes now.
    private var turns: AgentTurnStateStore?
    private var turnKeys: Set<String> = []
    /// Replans run (tests: a turn of a chat that is not hidden replans nothing).
    package private(set) var replans = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    package private(set) var setting: BrowserHibernationSetting = .fallback
    package private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page was last visible.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    private var shown: Set<String> = []
    private var releasing: Set<String> = []
    /// Existing shared LRU: visible pages plus the newest hidden untouched New Tabs. The spare
    /// pool is separate and never enters this set. Visibility updates touch only changed keys.
    package static var newTabCapacity: Int { 2 }
    private var newTabs = SurfaceRetention<String>(capacity: HiddenChatPages<Host>.newTabCapacity)
    private var excessNewTabs: Set<String> = []
    package func newTabIsExcess(_ key: String) -> Bool { excessNewTabs.contains(key) }
    /// Pages a release kept, and when each is asked again (``keptForNow(_:)``).
    private var retryAt: [String: ContinuousClock.Instant] = [:]
    /// Hidden pages whose workspace hibernates (``releaseForWorkspace(_:)``): they go without
    /// `browser.hibernation`, still only when nothing else keeps them; cleared when shown or closed.
    private var workspaceDue: Set<String> = []
    /// The one deadline for the next page to be let go; cancelled when none is due.
    private let deadline: any WorkspaceHibernationDeadline
    package private(set) var releasedCount = 0
    /// A page is due later and the timer for it runs (tests).
    package var hasDeadline: Bool { deadline.isScheduled }
    /// Hidden pages frozen now (`browser.freezeHiddenTabs`), each with the page and the control it
    /// froze through, so a page whose tab got another key (a provisional tab created) still thaws.
    private var frozenPages: [String: FrozenPage] = [:]
    /// The tabs whose page is frozen now (tests).
    package var frozen: Set<String> { Set(frozenPages.keys) }
    /// When a hidden page last had to stay awake: the engine refused to freeze it (it still counted
    /// it visible), or work woke it. It freezes `freezeSeconds` after that.
    /// Per page, not per key: a page can be under two keys (a provisional tab's alias).
    private var awakeSince: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    /// The one deadline for the next page to freeze; cancelled when no hidden page is due.
    private let freezeDeadline: any WorkspaceHibernationDeadline
    /// A page is due to freeze later and the timer for it runs (tests).
    package var hasFreezeDeadline: Bool { freezeDeadline.isScheduled }
    /// Every page is being asked what it holds (the quit's relaunch state): none freezes meanwhile.
    package private(set) var heldAwake = false

    /// - Parameters:
    ///   - host: the App's agent tab pages; it owns this planner.
    ///   - deadline: the one-shot timer of the next release.
    ///   - freezeDeadline: the one-shot timer of the next freeze.
    package init(host: Host, deadline: any WorkspaceHibernationDeadline, freezeDeadline: any WorkspaceHibernationDeadline) {
        self.host = host
        self.deadline = deadline
        self.freezeDeadline = freezeDeadline
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050); nothing to clean up.
    nonisolated deinit {}

    /// Re-plan only when the watch or the turn of a hidden or frozen page changes, never for another chat's turn:
    /// one agent's step in a shown chat replanned every hidden page (O(hidden) filters and a sort per event).
    package func followTurns(_ turns: AgentTurnStateStore) {
        self.turns = turns
        observeTurns(of: [], replanFirst: true)
    }

    /// Observes the turns of the pages a replan reads (`keys`): the watch and each one's busy state, nothing else.
    /// `replanFirst`: the observation's first value replans too (a new follow); a change of `keys` comes from a replan.
    private func observeTurns(of keys: Set<String>, replanFirst: Bool) {
        guard let turns else { return }
        turnKeys = keys
        turnObservation?.cancel()
        let read: @MainActor @Sendable () -> TurnsRead = { [weak self] in
            TurnsRead(watching: turns.watching, busy: keys.filter { self?.host?.pageTurnBusy($0) == true },
                      archived: keys.filter { self?.host?.pageArchived($0) == true })
        }
        // What the replan that armed this saw, read now: a turn that changes before the stream's first value
        // (it starts on a later turn) differs from it and replans, so no change between the two is lost.
        let seen: TurnsRead? = replanFirst ? nil : read()
        turnObservation = Task { [weak self] in
            var last = seen
            for await now in ObservationStream(read) where now != last {
                last = now
                self?.replan()
            }
        }
    }

    /// The turn facts a replan reads: whether the watch is up, which observed pages' chats work, and which are archived.
    private struct TurnsRead: Equatable, Sendable {
        var watching: Bool
        var busy: Set<String>
        var archived: Set<String>
    }

    /// Follows the turns of the pages hidden or frozen now, when they changed since the last observation.
    private func followHiddenTurns() {
        let keys = Set(hiddenAt.keys).union(frozenPages.keys)
        if keys != turnKeys { observeTurns(of: keys, replanFirst: false) }
    }

    package func stop() {
        turnObservation?.cancel()
        turnObservation = nil
        turns = nil
        deadline.cancel()
        freezeDeadline.cancel()
        for key in Array(frozenPages.keys) { thaw(key) }
    }

    package func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) {
        guard setting != self.setting || pressure != self.pressure else { return }
        (self.setting, self.pressure) = (setting, pressure)
        replan()
    }

    /// Seconds a hidden idle chat keeps its page: ``idleRelease``, ``idleReleaseUnderWarning`` under warning
    /// pressure, at once under critical (floored at ``minimumHidden`` by the caller).
    private var idleThreshold: Double {
        switch pressure {
        case .normal: return idleWait
        case .warning: return min(idleWait, Self.idleReleaseUnderWarning)
        case .critical: return 0
        }
    }

    /// The browser setting's own wait for a chat that it lets go on its own (auto discard), nil when it does not.
    private var settingThreshold: Double? {
        setting.isEnabled && setting.discardsAutomatically ? HibernationPlanner.threshold(setting, pressure: pressure) : nil
    }

    /// Tab `key` is a hidden untouched New Tab beyond the warm-page cap (it follows `browser.hibernation` alone).
    private func isExcessNewTab(_ key: String) -> Bool {
        excessNewTabs.contains(key) && host?.pageIsUntouchedNewTab(key) == true
    }

    /// Compares every page with whether its tab draws now, and reports the ones that changed.
    /// Whether the tab draws, not whether its view is still in a window: presentation changes
    /// come before the pane swaps its content, so the outgoing page is still on screen then.
    /// (A release checks the window again.)
    /// `changed`: the tabs this change is about (nil: every page), so a switch is O(changed tabs).
    package func sync(_ changed: Set<String>? = nil, _ isRendering: (String) -> Bool) {
        guard let host, let pages = host.hibernationPages() else { return }
        for key in changed ?? Set(pages.keys) where host.hibernationPage(key) != nil {
            let visible = isRendering(key)
            if visible != shown.contains(key) { pageVisibility(key, visible: visible) }
        }
    }

    /// Tab `key`'s page started or stopped drawing.
    package func pageVisibility(_ key: String, visible: Bool) {
        guard let host, host.hibernationPages() != nil else { return }
        noteNewTab(key, visible: visible)
        if visible {
            thaw(key)
            shown.insert(key)
            hiddenAt[key] = nil
            retryAt[key] = nil
            workspaceDue.remove(key)
            host.dropReleasedFrame(key)
        } else if host.hibernationPage(key) != nil {
            shown.remove(key)
            hiddenAt[key] = host.pageClock()
            replan()
        }
    }

    package func forget(_ key: String) {
        newTabs.remove(key)
        excessNewTabs.remove(key)
        thaw(key)
        shown.remove(key)
        workspaceDue.remove(key)
        hiddenAt[key] = nil
        retryAt[key] = nil
        host?.dropReleasedFrame(key)
    }

    /// Releases every page that is due and arms one deadline for the next.
    package func replan() {
        replans += 1
        defer { followHiddenTurns() }
        guard let host, let pages = host.hibernationPages() else { return }
        hiddenAt = hiddenAt.filter { host.hibernationPage($0.key) != nil }
        shown = shown.filter { host.hibernationPage($0) != nil }
        // A frozen page no longer under its key (closed, or its tab got another key) thaws; one still
        // hidden under its new key starts its hidden clock below and freezes again later.
        for (key, entry) in frozenPages where entry.page == nil || host.hibernationPage(key) !== entry.page { thaw(key) }
        let livePages = Set(pages.values.map(ObjectIdentifier.init))
        awakeSince = awakeSince.filter { livePages.contains($0.key) }
        startUnseenClocks(pages)
        replanFreeze()
        // A hidden idle chat's wait: its own, or the setting's when that lets chats go sooner on its own.
        let chatThreshold = max(min(settingThreshold ?? idleThreshold, idleThreshold), Self.minimumHidden)
        let current = host.pageClock()
        retryAt = retryAt.filter { hiddenAt[$0.key] != nil }
        var next: Double?
        // The least recently seen first: under pressure the oldest hidden chat goes before the others.
        for (key, at) in hiddenAt.sorted(by: { $0.value < $1.value })
        where !releasing.contains(key) && keepsPage(key, onScreen: false) == nil {
            // Its release kept it a moment ago: it is asked again once its recheck comes.
            if let retry = retryAt[key] {
                let wait = (retry - current).seconds
                if wait > 0 {
                    next = min(next ?? wait, wait)
                    continue
                }
                retryAt[key] = nil
            }
            let newTab = excessNewTabs.contains(key) && host.pageIsUntouchedNewTab(key)
            let threshold = newTab ? Self.minimumHidden : chatThreshold
            // Its workspace hibernates, or the chat is archived: due now.
            let dueNow = workspaceDue.contains(key) || (!newTab && host.pageArchived(key))
            let remaining = dueNow ? 0 : threshold - (current - at).seconds
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if keepsPage(key) == nil {
                host.releasePage(key)
            } else {
                // Still in its window: a hide comes before the pane swaps its content, and
                // the swap sends no event of its own. Look again, backing off the longer it
                // stays (as long as it is overdue), so a page kept in a window wakes rarely.
                let again = max(Self.onScreenRecheck, -remaining)
                next = min(next ?? again, again)
            }
        }
        if let next {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }

    /// Why tab `key`'s hidden page stays, or nil when it can go. `onScreen: false` leaves out
    /// whether its view is still in a window (planning a deadline: the pane takes it out after the hide).
    package func keepsPage(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? {
        // Chats always go once hidden and idle; an untouched New Tab beyond the cap follows `browser.hibernation`.
        if !setting.isEnabled, isExcessNewTab(key) { return .disabled }
        if heldAwake { return .keepsState }
        guard let host, host.pageMayRelease(key, onScreen: onScreen) else { return .unsupported }
        if host.pagePinned(key), !setting.includesPinnedTabs { return .pinned }
        // No watch, no known turn: a chat that looks idle may be working.
        if !host.pageTurnsKnown() { return .agentTurnsUnknown }
        // Working (its turn, a permission or question, a subagent or background command): it keeps its page.
        if host.pageTurnBusy(key) { return .agentBusy }
        return nil
    }

    /// A release of tab `key`'s page starts (``HiddenChatPagesHost/releasePage(_:)``): nil when one already
    /// runs. The page thaws first (it answers what it holds and draws its frame: a frozen page runs no
    /// script). Returns how long it was hidden, whether its workspace hibernates, the cause for the log, and
    /// whether it needs a first frame to go (a release `browser.hibernation` asks for, short of discarding on its own).
    package func beginRelease(_ key: String) -> (hiddenFor: Int, forWorkspace: Bool, cause: String, requiresFrame: Bool)? {
        guard let host, releasing.insert(key).inserted else { return nil }
        thaw(key)
        let hidden = hiddenAt[key].map { (host.pageClock() - $0).seconds } ?? 0
        let hiddenFor = Int(hidden)
        let forWorkspace = workspaceDue.contains(key)
        let newTab = isExcessNewTab(key)
        let archived = !newTab && host.pageArchived(key)
        let bySetting = settingThreshold.map { hidden >= max($0, Self.minimumHidden) } ?? false
        // The idle release (or the archive) made it due, not `browser.hibernation`: no first frame is needed.
        let byIdle = !forWorkspace && !bySetting && !newTab
        let requiresFrame = !forWorkspace && !byIdle && !setting.discardsAutomatically
        var cause = forWorkspace ? "workspace-idle hidden=\(hiddenFor)s" : pressure == .normal ? "timeout hidden=\(hiddenFor)s" : "memory-pressure=\(pressure.rawValue) hidden=\(hiddenFor)s"
        if byIdle { cause = (archived ? "archived-chat " : "idle-chat ") + cause }
        return (hiddenFor, forWorkspace, cause, requiresFrame)
    }

    /// The release of tab `key` asked the page what it holds; it no longer counts as running.
    package func endRelease(_ key: String) { releasing.remove(key) }

    /// The release of tab `key` kept its page (it held prompts, or said nothing in time): it is
    /// asked again after ``keptRecheck``, on the planner's own deadline, as nothing else may plan
    /// again (cmux#32277). Its hide or show resets that.
    package func keptForNow(_ key: String) {
        guard let host, hiddenAt[key] != nil else { return }
        retryAt[key] = host.pageClock() + .seconds(Self.keptRecheck)
        replan()
    }

    /// Tab `key` still shows `page`, hidden, and nothing keeps it: the release may go on.
    package func isDue(_ key: String, page: Host.Page) -> Bool {
        guard let host else { return false }
        return hiddenAt[key] != nil && host.hibernationPage(key) === page && keepsPage(key) == nil
    }

    /// Tab `key`'s page was let go.
    package func released(_ key: String) {
        newTabs.remove(key)
        excessNewTabs.remove(key)
        hiddenAt[key] = nil
        retryAt[key] = nil
        releasedCount += 1
    }

    /// Its workspace hibernates (plans/cmux-next/workspace-hibernation-DESIGN.md): hidden chat page
    /// `key` goes now unless its turn runs or waits, or the App keeps it. Returns why not, or nil when it started.
    @discardableResult
    package func releaseForWorkspace(_ key: String) -> HibernationPlanner.Exemption? {
        guard let host, host.hibernationPage(key) != nil else { return .disabled }
        workspaceDue.insert(key)
        if hiddenAt[key] == nil { hiddenAt[key] = host.pageClock() }
        if let kept = keepsPage(key) {
            followHiddenTurns() // its turn's end lets it go
            return kept
        }
        host.releasePage(key)
        return nil
    }

    // MARK: Freeze

    /// Tab `key` got a page (built or adopted from the spare): built while its tab does not draw (restored
    /// or opened in the background), it never hides, so its hidden clock starts now.
    package func pageBuilt(_ key: String) {
        if let host { noteNewTab(key, visible: host.pageDraws(key)) }
        guard let host, let pages = host.hibernationPages(), hiddenAt[key] == nil, !shown.contains(key), !host.pageDraws(key) else { return }
        startUnseenClocks(pages)
        replan()
    }

    private func noteNewTab(_ key: String, visible: Bool) {
        guard host?.pageIsUntouchedNewTab(key) == true else {
            newTabs.remove(key)
            excessNewTabs.remove(key)
            return
        }
        if visible { excessNewTabs.remove(key) }
        if !excessNewTabs.contains(key) { excessNewTabs.formUnion(newTabs.setVisible(key, visible)) }
    }

    /// Pages built while their tab does not draw, and never seen to hide, start their hidden clock now.
    private func startUnseenClocks(_ pages: [String: Host.Page]) {
        guard let host else { return }
        let current = host.pageClock()
        for key in pages.keys where hiddenAt[key] == nil && !shown.contains(key) && !releasing.contains(key) && !host.pageDraws(key) {
            noteNewTab(key, visible: false)
            hiddenAt[key] = current
        }
    }

    /// Thaws every frozen page something now keeps awake (its turn started), freezes every hidden
    /// page past `freezeSeconds`, and arms one deadline for the next.
    private func replanFreeze() {
        for key in Array(frozenPages.keys) where keepsAwake(key, onScreen: false) != nil { thaw(key) }
        guard setting.isEnabled, let threshold = setting.freezeSeconds else {
            freezeDeadline.cancel()
            return
        }
        guard let host, host.hibernationPages() != nil else { return freezeDeadline.cancel() }
        let current = host.pageClock()
        var next: Double?
        // Pages, not keys: a page can be under two keys (a provisional tab's alias resolves until the
        // tree drops it). Each page is planned once, from the latest hide of any of its keys, and one
        // being released or already frozen under any key is left alone.
        let releasingPages = Set(releasing.compactMap { host.hibernationPage($0) }.map(ObjectIdentifier.init))
        let frozenNow = Set(frozenPages.values.compactMap(\.page).map(ObjectIdentifier.init))
        var pages: [ObjectIdentifier: (key: String, at: ContinuousClock.Instant)] = [:]
        for (key, at) in hiddenAt {
            guard let page = host.hibernationPage(key) else { continue }
            let id = ObjectIdentifier(page)
            if let seen = pages[id], seen.at >= at { continue }
            pages[id] = (key, at)
        }
        for (page, hidden) in pages where !releasingPages.contains(page) && !frozenNow.contains(page)
            && keepsAwake(hidden.key, onScreen: false) == nil {
            let key = hidden.key
            var remaining = threshold - (current - hidden.at).seconds
            if let awake = awakeSince[page] { remaining = max(remaining, threshold - (current - awake).seconds) }
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if keepsAwake(key) != nil || host.hibernationPage(key).map({ host.freezeControl(of: $0) == nil }) ?? false {
                // Still in its window (the hide comes before the pane swaps its content), or its
                // Chromium browser is still being made: look again, backing off while it stays so.
                let again = max(Self.onScreenRecheck, -remaining)
                next = min(next ?? again, again)
            } else if !freeze(key) {
                next = min(next ?? threshold, threshold)
            }
        }
        if let next {
            freezeDeadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            freezeDeadline.cancel()
        }
    }

    /// Why tab `key`'s hidden page stays awake, or nil when it may freeze. Its own rules, not the
    /// release's: a page freezes whatever the hibernation mode and keeps all it holds, so a shell
    /// command run in it or another machine's chat does not keep it awake. `onScreen: false` leaves
    /// out whether its view is still in a window (planning: the pane takes it out after the hide).
    package func keepsAwake(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? {
        guard setting.isEnabled, setting.freezeSeconds != nil, !heldAwake else { return .disabled }
        guard let host, host.pageMayFreeze(key, onScreen: onScreen) else { return .unsupported }
        if host.pagePinned(key), !setting.includesPinnedTabs { return .pinned }
        // No watch, no known turn: a chat that looks idle may be working.
        if !host.pageTurnsKnown() { return .agentTurnsUnknown }
        if host.pageTurnBusy(key) { return .agentBusy }
        return nil
    }

    /// Freezes the page; false when the engine refused (it is asked again `freezeSeconds` later).
    private func freeze(_ key: String) -> Bool {
        guard let host, let page = host.hibernationPage(key), let control = host.freezeControl(of: page) else { return true }
        guard host.setFrozen(control, true) else {
            awakeSince[ObjectIdentifier(page)] = host.pageClock()
            logger.debug("agent page \(key, privacy: .public) freeze refused")
            return false
        }
        awakeSince[ObjectIdentifier(page)] = nil
        frozenPages[key] = FrozenPage(page: page, control: control)
        // Work for the page wakes it first: a push the frame pacer sends a hidden page (a reply, a
        // turn's end, a backlog), a script call (debug and automation actions) or a picture. The page
        // is found by itself, whatever key its tab has by then.
        host.setPageWork(page) { [weak self, weak page] in self?.pageWorkNeeds(page) }
        logger.debug("froze agent page \(key, privacy: .public)")
        return true
    }

    /// Thaws a frozen page (shown, its turn started, a push for it, or about to be released).
    /// The page is found by itself too: its tab may have got another key since it froze (a
    /// provisional tab created), and the entry keeps the old key until the next plan.
    private func thaw(_ key: String) {
        guard let host else { return }
        let page = host.hibernationPage(key)
        let frozenKey = frozenPages[key] != nil ? key : page.flatMap { page in frozenPages.first { $0.value.page === page }?.key }
        guard let frozenKey, let entry = frozenPages.removeValue(forKey: frozenKey) else { return }
        if let page = entry.page { host.setPageWork(page, nil) }
        host.setFrozen(entry.control, false)
        logger.debug("thawed agent page \(key, privacy: .public)")
    }

    /// Every page is asked what it holds (the quit's relaunch state): frozen pages thaw now,
    /// and none freezes until it ends; then the hidden ones are planned again.
    package func holdAwake(_ held: Bool) {
        guard held != heldAwake else { return }
        heldAwake = held
        if held {
            for key in Array(frozenPages.keys) { thaw(key) }
            freezeDeadline.cancel()
            deadline.cancel()
        } else {
            replan()
        }
    }

    /// Frozen page `page` has work coming (a push, a script call, a picture): it thaws before the
    /// work reaches it, and freezes again `freezeSeconds` later if it is still hidden and idle.
    private func pageWorkNeeds(_ page: Host.Page?) {
        guard let host, let page, let key = frozenPages.first(where: { $0.value.page === page })?.key else { return }
        thaw(key)
        awakeSince[ObjectIdentifier(page)] = host.pageClock()
        replan()
    }

    /// A frozen page and the control it froze through (its Chromium tab).
    private struct FrozenPage {
        weak var page: Host.Page?
        let control: Host.FreezeControl
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
