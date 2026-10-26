import CmuxNextHibernation
import CmuxNextMemory

// The memory histograms' discard and wake counts come from the page hibernation (p07-memory-016).
extension MemoryHistograms {
    /// The content kinds whose discards are counted: those whose discard path calls
    /// ``recordDiscard(kind:)`` through ``follow(_:agentPages:)``. Any other kind has no histogram
    /// (absent, never a measured 0) until its discard path records too.
    static let hibernationKinds = [ContentKind.browser, .agentPage].map(\.rawValue)

    /// Counts each page `hibernation` hibernates and each agent page `agentPages` releases as a
    /// discard of its kind, and records each woken page's time to be back.
    func follow(_ hibernation: BrowserHibernation, agentPages: AgentPageHibernation) {
        hibernation.onHibernate = { [weak self] in self?.recordDiscard(kind: ContentKind.browser.rawValue) }
        hibernation.onWakeMounted = { [weak self] in self?.recordWake($0) }
        agentPages.onRelease = { [weak self] in self?.recordDiscard(kind: ContentKind.agentPage.rawValue) }
    }
}
