package import CmuxNextCompat
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
    /// The chat's turn runs or waits on the person.
    func pageTurnBusy(_ key: String) -> Bool
    /// The App's own reasons a hidden page may be let go (this Mac's chat with a session, no New Tab page,
    /// no shell command run in it, a page that shows no crash notice); `onScreen` also asks it is out of its window.
    func pageMayRelease(_ key: String, onScreen: Bool) -> Bool
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
/// A page is let go only once cmux.json sets `browser.hibernation`
/// (`BrowserHibernationSetting.discardsAutomatically`), as for browser tabs, when it is hidden past the
/// browser pages' threshold (`browser.hibernation` and memory pressure, as `HibernationPlanner` sets it),
/// or when its workspace hibernates. It stays when its tab is pinned (unless the setting includes pinned
/// tabs), its chat's turn runs or waits on the person, or the App keeps it (``HiddenChatPagesHost/pageMayRelease(_:onScreen:)``).
/// A page waits at least ``minimumHidden`` even under critical pressure, so the composer's last keystrokes
/// reach acpmux. Events only, no polling: a page hides or shows, the setting or the pressure changes, and
/// one deadline for the next page to come due.
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

    /// The App's side; it owns this planner (weak: no cycle).
    private weak var host: Host?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    package private(set) var setting: BrowserHibernationSetting = .fallback
    package private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page was last visible.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    private var shown: Set<String> = []
    private var releasing: Set<String> = []
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

    package func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) {
        guard setting != self.setting || pressure != self.pressure else { return }
        (self.setting, self.pressure) = (setting, pressure)
        replan()
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
        if visible {
            thaw(key)
            shown.insert(key)
            hiddenAt[key] = nil
            workspaceDue.remove(key)
            host.dropReleasedFrame(key)
        } else if host.hibernationPage(key) != nil {
            shown.remove(key)
            hiddenAt[key] = host.pageClock()
            replan()
        }
    }

    package func forget(_ key: String) {
        thaw(key)
        shown.remove(key)
        workspaceDue.remove(key)
        hiddenAt[key] = nil
        host?.dropReleasedFrame(key)
    }

    /// Releases every page that is due and arms one deadline for the next.
    package func replan() {
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
        guard setting.discardsAutomatically,
              let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            deadline.cancel()
            return
        }
        let current = host.pageClock()
        var next: Double?
        for (key, at) in hiddenAt where !releasing.contains(key) && keepsPage(key, onScreen: false) == nil {
            let remaining = threshold - (current - at).seconds
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
        if !setting.isEnabled { return .disabled }
        let forWorkspace = workspaceDue.contains(key)
        // No `browser.hibernation` written: a hidden chat keeps its page (nothing goes on its own),
        // unless its workspace hibernates (the person's workspace setting asked).
        if !setting.discardsAutomatically, !forWorkspace { return .keepsState }
        guard let host, host.pageMayRelease(key, onScreen: onScreen) else { return .unsupported }
        if host.pagePinned(key), !setting.includesPinnedTabs { return .pinned }
        // No watch, no known turn: a chat that looks idle may be working.
        if !host.pageTurnsKnown() { return .agentTurnsUnknown }
        if host.pageTurnBusy(key) { return .agentBusy }
        return nil
    }

    /// A release of tab `key`'s page starts (``HiddenChatPagesHost/releasePage(_:)``): nil when one already
    /// runs. The page thaws first (it answers what it holds and draws its frame: a frozen page runs no
    /// script). Returns how long it was hidden and whether its workspace hibernates, for the log.
    package func beginRelease(_ key: String) -> (hiddenFor: Int, forWorkspace: Bool)? {
        guard let host, releasing.insert(key).inserted else { return nil }
        thaw(key)
        return (hiddenAt[key].map { Int((host.pageClock() - $0).seconds) } ?? 0, workspaceDue.contains(key))
    }

    /// The release of tab `key` asked the page what it holds; it no longer counts as running.
    package func endRelease(_ key: String) { releasing.remove(key) }

    /// Tab `key` still shows `page`, hidden, and nothing keeps it: the release may go on.
    package func isDue(_ key: String, page: Host.Page) -> Bool {
        guard let host else { return false }
        return hiddenAt[key] != nil && host.hibernationPage(key) === page && keepsPage(key) == nil
    }

    /// Tab `key`'s page was let go.
    package func released(_ key: String) {
        hiddenAt[key] = nil
        releasedCount += 1
    }

    /// Its workspace hibernates (plans/cmux-next/workspace-hibernation-DESIGN.md): hidden chat page
    /// `key` goes now unless its turn runs or waits, or the App keeps it. Returns why not, or nil when it started.
    @discardableResult
    package func releaseForWorkspace(_ key: String) -> HibernationPlanner.Exemption? {
        guard let host, host.hibernationPage(key) != nil else { return .disabled }
        workspaceDue.insert(key)
        if hiddenAt[key] == nil { hiddenAt[key] = host.pageClock() }
        if let kept = keepsPage(key) { return kept }
        host.releasePage(key)
        return nil
    }

    // MARK: Freeze

    /// Tab `key` got a page (built or adopted from the spare): built while its tab does not draw (restored
    /// or opened in the background), it never hides, so its hidden clock starts now.
    package func pageBuilt(_ key: String) {
        guard let host, let pages = host.hibernationPages(), hiddenAt[key] == nil, !shown.contains(key), !host.pageDraws(key) else { return }
        startUnseenClocks(pages)
        replan()
    }

    /// Pages built while their tab does not draw, and never seen to hide, start their hidden clock now.
    private func startUnseenClocks(_ pages: [String: Host.Page]) {
        guard let host else { return }
        let current = host.pageClock()
        for key in pages.keys where hiddenAt[key] == nil && !shown.contains(key) && !releasing.contains(key) && !host.pageDraws(key) {
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
