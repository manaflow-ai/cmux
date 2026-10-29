public import CmuxNextResources
public import CmuxNextWakeups

extension TabStripView {
    /// CPU and memory for the hover card. Sampled only while a card is
    /// pending or shown.
    public var resourceSource: (any ResourceSampleSource)? { hoverCard.resources.source }

    /// Samples the hover card's tab from `source`, each next sample on `deadlines`, the app's one deadline
    /// scheduler (`AppServices.mainDeadlines`).
    public func setResourceSource(_ source: (any ResourceSampleSource)?, deadlines: MainDeadlineScheduler) {
        hoverCard.resources.setSource(source, deadlines: deadlines)
    }

    /// True while the hover card samples resources (tests, diagnostics).
    public var isSamplingResources: Bool { hoverCard.resources.isOpen }
}
