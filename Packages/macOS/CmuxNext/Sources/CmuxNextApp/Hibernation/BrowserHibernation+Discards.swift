import CmuxNextHibernation

/// What browser and agent page hibernation report to the discard planner's last inputs
/// (`discards`, shown by `debug.discards`).
extension BrowserHibernation {
    /// Records an owner's report now.
    func noteDiscard(_ event: ContentDiscardPlanner.Event) {
        discards.note(event, at: .now)
    }

    /// The agent page hibernation reports into the same planner.
    func agentPagesDidChange() {
        guard let agentPages else { return }
        discards.track(.agentPage)
        agentPages.noteDiscard = { [weak self] event in self?.noteDiscard(event) }
    }

    /// A planner pass's verdict on every hidden browser page (`hiddenAt`: when each was last
    /// visible): its exemption, else eligible.
    func notePlannedDiscards(_ hiddenAt: [String: ContinuousClock.Instant], now: ContinuousClock.Instant) {
        guard let cache else { return }
        for key in cache.lifecycle.keys(in: .mountedHidden) {
            guard let at = hiddenAt[key] else { continue }
            let hidden = now - at
            let seconds = Double(hidden.components.seconds) + Double(hidden.components.attoseconds) / 1e18
            discards.note(.planned(key, .browser, hiddenFor: seconds, exemptions[key].map(CanDiscardResult.init) ?? .eligible), at: now)
        }
    }
}
