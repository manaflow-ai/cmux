/// What hover shows in a strip right now, for `debug.surfaces`.
public struct TabStripHoverState: Equatable, Sendable {
    /// The trailing buttons are shown (pointer, open menu, VoiceOver).
    public var buttonsRevealed: Bool
    public var hoveredTab: String?
    /// Tabs whose x is shown.
    public var closeShown: [String]
}

extension TabStripView {
    public var hoverState: TabStripHoverState {
        TabStripHoverState(
            buttonsRevealed: buttonsReveal.isRevealed,
            hoveredTab: hoveredID?.rawValue,
            closeShown: displayed.compactMap { cells[$0.id]?.closeButtonRect != nil ? $0.id.rawValue : nil }
        )
    }
}
