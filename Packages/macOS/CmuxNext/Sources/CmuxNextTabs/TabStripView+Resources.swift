public import CmuxNextResources

extension TabStripView {
    /// CPU and memory for the hover card. Sampled only while a card is
    /// pending or shown.
    public var resourceSource: (any ResourceSampleSource)? {
        get { hoverCard.resources.source }
        set { hoverCard.resources.setSource(newValue) }
    }

    /// True while the hover card samples resources (tests, diagnostics).
    public var isSamplingResources: Bool { hoverCard.resources.isOpen }
}
