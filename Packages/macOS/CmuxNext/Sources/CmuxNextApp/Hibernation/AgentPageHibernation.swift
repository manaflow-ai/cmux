import AppKit
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
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
/// Hidden chat pages also have a page warm budget (`WarmSetBudget.pageCapacity`, a budget of their
/// own the size of the browser pages', perf-lead.md row 15): past it the chats the person left
/// longest ago go once hidden `HibernationPlanner.overBudgetMinimumHidden`, not after the whole
/// timeout, ranked by `HibernationPlanner.overBudget` as browser pages are. A pane's shown chat in
/// a workspace on screen or left last (`fronts`, `.warm`) stays out of the budget, so a switch back
/// shows a live page; one in a workspace left before that counts with a bounded credit, so the
/// parked workspaces do not hold a page each. A front that stops being warm counts its minute
/// from then (`countedAt`), not from its hide. Releases go a few at a time
/// (`HibernationPlanner.Pace`, counting the ones in flight), as browser pages do, so a switch
/// that parks a workspace's chats starts no burst of snapshots and retires in its frames.
///
/// A page stays when its tab is pinned (unless the setting includes pinned tabs), its chat's
/// turn runs or waits on the person (acpmux's turn state, `AgentTurnStateStore`), it is a New
/// Tab page or another machine's chat, or a shell command ran in it (closing the page ends the
/// command or drops its output). A page waits at
/// least ``minimumHidden`` even under critical pressure, so the composer's last keystrokes reach
/// acpmux. Events only, no polling: a page hides or shows (`TabContentCache`'s presentation
/// changes), the setting or the pressure changes, and one deadline for the next page to come due.
@MainActor
final class AgentPageHibernation {
    static let minimumHidden: Double = 10
    /// How soon a due page still in its window is first looked at again.
    static let onScreenRecheck: Double = 1

    /// The agent tab store once the App made it (no agent tab yet: nothing to release).
    private let store: () -> AgentTabStore?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private(set) var setting: BrowserHibernationSetting = .fallback
    private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page was last visible.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    /// When each hidden page last became counted in the warm budget (its front stopped being warm).
    private var countedAt: [String: ContinuousClock.Instant] = [:]
    private var shown: Set<String> = []
    private var releasing: Set<String> = []
    private let deadline = DemandTimer(owner: "AgentPageHibernation")
    /// The acpmux turn state of the tab's chat; injected by the App.
    var turnState: (String) -> AgentTurnState? = { _ in nil }
    /// The acpmux turn watch is up. While it is down no chat's turn is known, so every chat counts as busy.
    var turnsWatched: () -> Bool = { true }
    /// What the page holds that acpmux does not (attachments, shell text, scroll), kept with its
    /// tab when it lets go; nil when a connected page does not answer (tests set it: their page
    /// never loads).
    var wakeState: @MainActor (AgentPaneView) async -> AgentPaneWakeState? = { await $0.wakeState(limit: .seconds(3)) }
    var isPinned: (String) -> Bool = { _ in false }
    /// Hidden chat pages kept live (nil: no budget, the timeout alone).
    var warmPages: () -> Int? = { nil }
    /// The tab each pane shows, on screen or not, and whether it counts in the budget (`BrowserHibernation.fronts`).
    var fronts: () -> [String: HibernationPlanner.Front] = { [:] }
    /// The pane still hosting tab `key`'s page lets it go (it shows the tab again on demand).
    var displace: (String) -> Void = { _ in }
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    private(set) var releasedCount = 0
    /// Releases in flight (asking the page for its wake state and frame); tests read it.
    var releasingCount: Int { releasing.count }
    /// A page is due later and the timer for it runs (tests).
    var hasDeadline: Bool { deadline.isScheduled }
    /// Seconds from the last plan to the next page's deadline; nil when none (tests).
    private(set) var nextCheck: Double?
    private var turnObservation: Task<Void, Never>?

    init(tabs: @escaping () -> AgentTabStore?) {
        store = tabs
    }

    /// Wired to the App: never makes the agent tab store (that starts acpmux), follows the panes'
    /// presentation changes, and lets the pane holding a released page go.
    convenience init(services: AppServices) {
        self.init(tabs: { [weak services] in services?.madeAgentTabs })
        isPinned = { [weak services] key in services?.locateTab(key)?.0.pinned ?? false }
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
        warmPages = { [weak cache] in cache?.warmBudget.pageCapacity }
        fronts = { [weak cache] in cache?.hibernation?.fronts ?? [:] }
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

    func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) {
        guard setting != self.setting || pressure != self.pressure else { return }
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
        countedAt[key] = nil
        if visible {
            shown.insert(key)
            hiddenAt[key] = nil
            tabs.launchImages.drop(key)
        } else if tabs.existingView(key) != nil {
            shown.remove(key)
            hiddenAt[key] = now()
            replan()
        }
    }

    /// Tabs became or stopped being a pane's shown tab, warm or parked (`NeighborTabs.fronts`): a
    /// hidden chat among them changes its place in the budget. Panes report their new shown tab
    /// after the hide of the old one, so the hide planned with the fronts before the change.
    /// `becameCounted`: the ones that stopped being warm, so the person left them now (the
    /// budget's minute starts now, however long ago they hid).
    func frontsDidChange(_ changed: Set<String>, becameCounted: Set<String> = []) {
        let current = now()
        for key in becameCounted where hiddenAt[key] != nil { countedAt[key] = current }
        guard changed.contains(where: { hiddenAt[$0] != nil }) else { return }
        replan()
    }

    func forget(_ key: String) {
        shown.remove(key)
        hiddenAt[key] = nil
        countedAt[key] = nil
        store()?.launchImages.drop(key)
    }

    /// Releases the pages that are due, a few at a time (`HibernationPlanner.paced`, counting the
    /// releases in flight), and arms one deadline for the next.
    func replan() {
        guard let tabs = store() else { return }
        hiddenAt = hiddenAt.filter { tabs.existingView($0.key) != nil }
        countedAt = countedAt.filter { hiddenAt[$0.key] != nil }
        shown = shown.filter { tabs.existingView($0) != nil }
        guard let planned = plan() else {
            deadline.cancel()
            nextCheck = nil
            return
        }
        let pace = HibernationPlanner.Pace.at(pressure)
        let pass = HibernationPlanner.paced(planned.due, inFlight: releasing.count, pace: pace)
        for key in pass.now { release(key) }
        var next = planned.next
        if pass.more { next = min(next ?? pace.interval, pace.interval) }
        nextCheck = next
        if let next {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }

    /// The hidden pages due now (the timed ones longest hidden first, then the ones past the
    /// budget in budget order) and seconds until the next one is; nil when hibernation is off.
    private func plan() -> (due: [String], next: Double?)? {
        guard let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            return nil
        }
        let current = now()
        var next: Double?
        // Pages that must stay (a busy turn, pinned) neither go for the budget nor hold a place in it.
        let releasable = hiddenAt.filter { !releasing.contains($0.key) && keepsPage($0.key, onScreen: false) == nil }
            .map { (key: $0.key, age: (current - $0.value).seconds) }
        let fronts = self.fronts()
        let overOrder = HibernationPlanner.overBudget(releasable.map { (key: $0.key, idleness: $0.age, front: fronts[$0.key]) },
                                                      warmPages: warmPages(), timeout: threshold)
        let over = Set(overOrder)
        let overThreshold = min(threshold, max(Self.minimumHidden, HibernationPlanner.overBudgetMinimumHidden))
        var timed: [(key: String, age: Double)] = []
        var overDue: Set<String> = []
        for (key, age) in releasable {
            var remaining = threshold - age
            let timedOut = remaining <= 0
            if over.contains(key) {
                // The person left it when it hid or, for a front that stopped being warm, then.
                let budgetAge = min(age, countedAt[key].map { (current - $0).seconds } ?? age)
                remaining = min(remaining, overThreshold - budgetAge)
            }
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if keepsPage(key) == nil {
                if timedOut { timed.append((key, age)) } else { overDue.insert(key) }
            } else {
                // Still in its window: a hide comes before the pane swaps its content, and
                // the swap sends no event of its own. Look again, backing off the longer it
                // stays (as long as it is overdue), so a page kept in a window wakes rarely.
                let again = max(Self.onScreenRecheck, -remaining)
                next = min(next ?? again, again)
            }
        }
        timed.sort { $0.age != $1.age ? $0.age > $1.age : $0.key < $1.key }
        return (timed.map(\.key) + overOrder.filter { overDue.contains($0) }, next)
    }

    /// Why tab `key`'s hidden page stays, or nil when it can go. `onScreen: false` leaves out
    /// whether its view is still in a window (planning a deadline: the pane takes it out after the hide).
    func keepsPage(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? {
        if !setting.isEnabled { return .disabled }
        guard let tabs = store(), Self.canRelease(key, in: tabs, onScreen: onScreen) else { return .unsupported }
        if isPinned(key), !setting.includesPinnedTabs { return .pinned }
        // No watch, no known turn: a chat that looks idle may be working.
        if !turnsWatched() { return .agentTurnsUnknown }
        if let turn = turnState(key), turn == .working || turn == .needsInput { return .agentBusy }
        return nil
    }

    /// A chat of this Mac's acpmux with a session, off screen, not a New Tab page, and no shell
    /// command run in it.
    private static func canRelease(_ key: String, in tabs: AgentTabStore, onScreen: Bool) -> Bool {
        let key = tabs.resolve(key)
        guard let view = tabs.views[key], !(onScreen && isOnScreen(view)), view.model.newTab == nil, !view.model.shell.hasRuns,
              tabs.newTabPages[key] == nil, let (record, _) = tabs.lookup(key),
              AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost) == .local,
              tabs.daemonForTab(key)?.isLocal != false else { return false }
        return (tabs.sessions[key] ?? view.model.sessionId ?? record.session) != nil
            && tabs.remoteSeeds[key] == nil && tabs.remoteCreations[key] == nil && tabs.remoteStarts[key] == nil
    }

    private static func isOnScreen(_ view: AgentPaneView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// Keeps the page's frame and what it holds that acpmux does not, then lets the page go if it
    /// is still the same hidden page.
    private func release(_ key: String) {
        guard let tabs = store(), let view = tabs.existingView(key), releasing.insert(key).inserted else { return }
        let readWake = wakeState
        Task { @MainActor [weak self] in
            let wake = await readWake(view)
            let frame = await Self.frame(view)
            guard let self else { return }
            releasing.remove(key)
            // A connected page that did not say what it holds (a large attachment still encoding)
            // stays: letting it go would drop its chips. The next plan asks again.
            if wake == nil, view.model.hasHandshake {
                logger.info("agent page \(key, privacy: .public) kept: no wake state in time")
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
            displace(key)
            // The tab keeps its session and every other state: the next show builds the page again.
            let stored = tabs.resolve(key)
            if let session = view.model.sessionId { tabs.sessions[stored] = session }
            tabs.wakeStates[stored] = wake.flatMap { $0.isEmpty ? nil : $0 }
            tabs.views[stored] = nil
            tabs.retirer.retire(view)
            tabs.stopCustomizationWhenUnused()
            hiddenAt[key] = nil
            releasedCount += 1
            logger.info("released agent page \(key, privacy: .public)")
        }
    }

    /// Still the same hidden page and still due by the plan now: budget membership can change
    /// back while its frame is taken (a front warm again, a chat closed that freed a place).
    private func isDue(_ key: String, _ view: AgentPaneView, in tabs: AgentTabStore) -> Bool {
        hiddenAt[key] != nil && tabs.existingView(key) === view && keepsPage(key) == nil && plan()?.due.contains(key) == true
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

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
