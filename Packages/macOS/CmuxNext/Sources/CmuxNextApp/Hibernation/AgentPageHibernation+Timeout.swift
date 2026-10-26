import AppKit
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextHibernation
import os

// AgentPageHibernation's own timeout and live hidden budget, which let hidden agent pages go while
// `pageLifecycle` is off (with it on, the page lifecycle's planner does: AgentPageHibernation.swift).
extension AgentPageHibernation {
    /// Releases every page that is due (past the timeout, or the oldest past ``liveHiddenLimit``)
    /// and arms one deadline for the next.
    func replan() {
        guard lifecycle == nil, let tabs = store() else { return }
        hiddenAt = hiddenAt.filter { tabs.existingView($0.key) != nil }
        shown = shown.filter { tabs.existingView($0) != nil }
        guard let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            deadlineDelay = nil
            deadline.cancel()
            return
        }
        let current = now()
        var next: Double?
        // The hidden pages still live: not on their way out.
        var live = hiddenAt.filter { !releasing.contains($0.key) }
        for (key, at) in live where keepsPage(key, onScreen: false) == nil {
            let remaining = threshold - (current - at).seconds
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if keepsPage(key) == nil {
                release(key)
                live[key] = nil
            } else {
                // Still in its window: a hide comes before the pane swaps its content, and
                // the swap sends no event of its own. Look again, backing off the longer it
                // stays (as long as it is overdue), so a page kept in a window wakes rarely.
                let again = max(Self.onScreenRecheck, -remaining)
                next = min(next ?? again, again)
            }
        }
        if let again = releaseOverLimit(live, at: current) { next = min(next ?? again, again) }
        deadlineDelay = next
        if let next {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
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

    /// Lets the least recently shown pages of `live` that may go, go until at most
    /// ``liveHiddenLimit`` stay. A page hidden less than ``minimumHidden`` waits, and one still in
    /// its window is looked at again as in the timeout.
    /// - Returns: While still over the limit, how soon to look again (seconds); else nil.
    private func releaseOverLimit(_ live: [String: ContinuousClock.Instant], at current: ContinuousClock.Instant) -> Double? {
        guard let limit = liveHiddenLimit else { return nil }
        var excess = live.count - limit
        guard excess > 0 else { return nil }
        var next: Double?
        for (key, at) in live.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) where keepsPage(key, onScreen: false) == nil {
            guard excess > 0 else { break }
            let young = Self.minimumHidden - (current - at).seconds
            if young > 0 {
                // Oldest first: every page after this one is younger still.
                return min(next ?? young, young)
            }
            // A page still in its window counts as going: it goes once the pane takes it out.
            excess -= 1
            if keepsPage(key) == nil {
                release(key)
            } else {
                let again = max(Self.onScreenRecheck, -young)
                next = min(next ?? again, again)
            }
        }
        return next
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

    func isDue(_ key: String, _ view: AgentPaneView, in tabs: AgentTabStore) -> Bool {
        hiddenAt[key] != nil && tabs.existingView(key) === view && keepsPage(key) == nil
    }

    /// The page as last drawn; nil when it does not answer in time (it then shows its loading
    /// state when it comes back).
    static func frame(_ view: AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? {
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await view.pageImage().flatMap { image in image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size, appearance) } }
        }
        return frame.flatMap { $0 }
    }
}
