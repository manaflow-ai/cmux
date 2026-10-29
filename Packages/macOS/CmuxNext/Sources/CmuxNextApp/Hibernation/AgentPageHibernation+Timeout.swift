import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextWakeups
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
        let current = now()
        // No `browser.hibernation` written: no hidden chat goes on its own (trunk #25920).
        guard setting.discardsAutomatically,
              let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            let kept: HibernationPlanner.Exemption = setting.isEnabled ? .keepsState : .disabled
            for (key, at) in hiddenAt { noteDiscard(.planned(key, .agentPage, hiddenFor: (current - at).seconds, DiscardEligibility(keptFor: kept))) }
            deadlineDelay = nil
            deadline.cancel()
            return
        }
        var next: Double?
        // The hidden pages still live: not on their way out.
        var live = hiddenAt.filter { !releasing.contains($0.key) }
        // Left to the urgent pass at critical pressure: one chat per urgent pace interval, oldest first.
        let paced = leavesCriticalEventToUrgentPass && pressure == .critical
        if let hold = noReleaseBefore, current >= hold { noReleaseBefore = nil }
        for (key, at) in live.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            // Each hidden page's verdict, as the owner decides it (`debug.discards`).
            let kept = keepsPage(key, onScreen: false)
            noteDiscard(.planned(key, .agentPage, hiddenFor: (current - at).seconds, kept.map { DiscardEligibility(keptFor: $0) } ?? DiscardEligibility()))
            guard kept == nil else { continue }
            let remaining = threshold - (current - at).seconds
            if remaining > 0 {
                next = min(next ?? remaining, remaining)
            } else if paced, let hold = noReleaseBefore {
                let wait = (hold - current).seconds
                next = min(next ?? wait, wait)
            } else if keepsPage(key) == nil {
                release(key)
                live[key] = nil
                if paced { holdReleases() }
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
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { [weak self] in self?.replan() }
        } else {
            deadline.cancel()
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
        // No `browser.hibernation` written: a hidden chat keeps its page (nothing goes on its own),
        // unless its workspace hibernates (the person's workspace setting asked).
        if !setting.discardsAutomatically, !workspaceDue.contains(key) { return .keepsState }
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
        // visibility-walk-allow: the last check before a page is let go must see what still draws; a pane parks a hidden page in its window (isHidden), so the view tree says it, as a hit test reads it
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// The page as last drawn; nil when it does not answer in time (it then shows its loading
    /// state when it comes back).
    static func frame(_ view: AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? {
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await view.pageImage().flatMap { image in image.bestCGImage.map { ($0, image.size, appearance) } }
        }
        return frame.flatMap { $0 }
    }
}

// The app's one urgent pass over tabs, chats and pages (`UrgentDiscardRanker.run`, feature
// `memoryUrgentDiscardRanking`) ranks the hidden chats with the browser tabs and cmux pages. With
// `pageLifecycle` on, the chats are pages of the lifecycle and it ranks them.
extension AgentPageHibernation: UrgentDiscardOwner {
    /// The hidden chats that may go now: live, hidden at least ``minimumHidden`` (the composer's last
    /// keystrokes reach acpmux), out of their window, and nothing keeps them. O(hidden chats).
    func urgentCandidates() -> [UrgentDiscardRanker.Candidate] {
        guard lifecycle == nil, let tabs = store() else { return [] }
        let current = now()
        return hiddenAt.compactMap { entry -> UrgentDiscardRanker.Candidate? in
            let hiddenFor = (current - entry.value).seconds
            guard hiddenFor >= Self.minimumHidden, !releasing.contains(entry.key), tabs.existingView(entry.key) != nil,
                  keepsPage(entry.key) == nil else { return nil }
            return UrgentDiscardRanker.Candidate(key: entry.key, kind: .agentPage, hiddenFor: hiddenFor)
        }
    }

    /// Lets chat `key`'s page go (after its wake state and frame); false when it is not a hidden chat
    /// that may go now.
    func urgentDiscard(_ key: String) -> Bool {
        guard hiddenAt[key] != nil, !releasing.contains(key), keepsPage(key) == nil else { return false }
        release(key)
        return releasing.contains(key)
    }

    /// The timeout lets no chat go for one urgent pace interval from now.
    func urgentPassDidRun() {
        holdReleases()
        replan()
    }

    func holdReleases() {
        noReleaseBefore = now() + .seconds(HibernationPlanner.Pace.chromeUrgent.interval)
    }
}
