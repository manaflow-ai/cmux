import AppKit
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Lets hidden agent chat pages go (cx-x15rz), only once cmux.json sets `browser.hibernation`
/// (`BrowserHibernationSetting.discardsAutomatically`), as for browser tabs: a page built again
/// keeps what ``AgentPaneWakeState`` carries (chips, shell text, scroll) and acpmux's draft, but
/// not an open menu or popover, the caret, a queued prompt being edited or an IME composition
/// (Leo, 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?"). Each chat tab's page is a web view with its own
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
    private var shown: Set<String> = []
    private var releasing: Set<String> = []
    /// Hidden pages whose workspace hibernates (`releaseForWorkspace`): they go without
    /// `browser.hibernation`, still only when nothing else keeps them; cleared when shown or closed.
    private var workspaceDue: Set<String> = []
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
    /// The pane still hosting tab `key`'s page lets it go (it shows the tab again on demand).
    var displace: (String) -> Void = { _ in }
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    private(set) var releasedCount = 0
    /// A page is due later and the timer for it runs (tests).
    var hasDeadline: Bool { deadline.isScheduled }
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
        if visible {
            shown.insert(key)
            hiddenAt[key] = nil
            workspaceDue.remove(key)
            tabs.launchImages.drop(key)
        } else if tabs.existingView(key) != nil {
            shown.remove(key)
            hiddenAt[key] = now()
            replan()
        }
    }

    func forget(_ key: String) {
        shown.remove(key)
        workspaceDue.remove(key)
        hiddenAt[key] = nil
        store()?.launchImages.drop(key)
    }

    /// Releases every page that is due and arms one deadline for the next.
    func replan() {
        guard let tabs = store() else { return }
        hiddenAt = hiddenAt.filter { tabs.existingView($0.key) != nil }
        shown = shown.filter { tabs.existingView($0) != nil }
        guard setting.discardsAutomatically,
              let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            deadline.cancel()
            return
        }
        let current = now()
        var next: Double?
        for (key, at) in hiddenAt where !releasing.contains(key) && keepsPage(key, onScreen: false) == nil {
            let remaining = threshold - (current - at).seconds
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if keepsPage(key) == nil {
                release(key)
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
    func keepsPage(_ key: String, onScreen: Bool = true) -> HibernationPlanner.Exemption? {
        if !setting.isEnabled { return .disabled }
        let forWorkspace = workspaceDue.contains(key)
        // No `browser.hibernation` written: a hidden chat keeps its page (nothing goes on its own),
        // unless its workspace hibernates (the person's workspace setting asked).
        if !setting.discardsAutomatically, !forWorkspace { return .keepsState }
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
        // A crashed page keeps its notice: a rebuild would reload it without the person's Reload.
        guard let view = tabs.views[key], !view.showsCrashNotice, !(onScreen && isOnScreen(view)), view.model.newTab == nil, !view.model.shell.hasRuns,
              tabs.newTabPages[key] == nil, let (record, _) = tabs.lookup(key),
              AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost, listedHere: true) == .local,
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
        let hiddenFor = hiddenAt[key].map { Int((now() - $0).seconds) } ?? 0
        let cause = workspaceDue.contains(key) ? "workspace-idle hidden=\(hiddenFor)s" : pressure == .normal ? "timeout hidden=\(hiddenFor)s" : "memory-pressure=\(pressure.rawValue) hidden=\(hiddenFor)s"
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
            // Notice, not info: the field log keeps it (the page is built again when shown).
            logger.notice("released agent page \(key, privacy: .public) cause=\(cause, privacy: .public); it is built again when shown")
        }
    }

    /// Its workspace hibernates (plans/cmux-next/workspace-hibernation-DESIGN.md): hidden chat page
    /// `key` goes now unless its turn runs or waits, a shell command ran in it, or it is not this
    /// Mac's chat. Returns why not, or nil when it started.
    @discardableResult
    func releaseForWorkspace(_ key: String) -> HibernationPlanner.Exemption? {
        guard let tabs = store(), tabs.existingView(key) != nil else { return .disabled }
        workspaceDue.insert(key)
        if hiddenAt[key] == nil { hiddenAt[key] = now() }
        if let kept = keepsPage(key) { return kept }
        release(key)
        return nil
    }

    private func isDue(_ key: String, _ view: AgentPaneView, in tabs: AgentTabStore) -> Bool {
        hiddenAt[key] != nil && tabs.existingView(key) === view && keepsPage(key) == nil
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
