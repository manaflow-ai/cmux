import CmuxNextHibernation

// The critical memory event's one urgent pass over tabs, chats and pages (p13-webui-092, feature
// `memoryUrgentDiscardRanking`), as Chrome's `UrgentPageDiscardingPolicy` discards one page per
// critical event (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc) in
// `PageDiscardingHelper`'s order (page_discarding_helper.cc). The browser hibernation is one owner
// (its tabs); the agent chats and the cmux page lifecycle are the others (`urgentDiscardOwners`).
extension BrowserHibernation: UrgentDiscardOwner {
    /// Ranks every owner's hidden pages once and lets the first go (``UrgentDiscardRanker/run(_:)``):
    /// a browser tab through its probe, a chat after its wake state, a page at once. Every owner's own
    /// paced discards then wait one of its pace intervals.
    func urgentPass() {
        guard let cache else { return }
        lastUrgentPass = urgentRanker.run([self] + urgentDiscardOwners())
        for candidate in lastUrgentPass.discards {
            cache.trace(candidate.key, "discard (\(DiscardReason.urgent.rawValue), ranked \(candidate.kind.rawValue))")
        }
    }

    /// The paced passes discard no tab for one critical pace interval from now: the critical event's
    /// discard is the urgent pass's.
    func holdPacedDiscards() {
        urgentHoldEnds = now() + .seconds(HibernationPlanner.criticalPace.interval)
    }

    /// The hidden browser tabs the urgent pass may take now (``HibernationPlanner/urgentCandidates(_:candidates:)``).
    func urgentCandidates() -> [UrgentDiscardRanker.Candidate] {
        HibernationPlanner.urgentCandidates(setting, candidates: hiddenCandidates(now: now()).map(\.facts))
    }

    /// Starts tab `key`'s discard probe (the discard finishes on its own turn); false when a probe
    /// already runs for it or it is no hidden browser tab now.
    func urgentDiscard(_ key: String) -> Bool {
        guard !probing.contains(key) else { return false }
        prepare(key, for: .urgent)
        return probing.contains(key)
    }

    /// The paced passes wait one critical pace interval; the next look is armed for its end.
    func urgentPassDidRun() {
        holdPacedDiscards()
        replan()
    }
}
