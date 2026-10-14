import CoreGraphics

extension LayoutStyle {
    /// The dim over each unfocused pane while a screen has more than one.
    /// The Ghostty config's unfocused-split dim, when it dims, takes every
    /// unfocused pane at its own amount and fill. Otherwise `inactivePaneDimming`
    /// applies when the model dims inactive panes, or with appearance.borders
    /// none, where the ring is off and the dim stands in for it when the
    /// indicator asked for the border and nothing else.
    func inactiveDim(dimsInactive: Bool) -> (amount: CGFloat, fill: PaneOverlayView.DimFill) {
        if unfocusedPaneDim.amount > 0 { return (unfocusedPaneDim.amount, .ghostty(unfocusedPaneDim.fill)) }
        // Floating panes with the ring off dim like a border-only indicator without lines.
        let ringless = floatingPanes && !focusRing.enabled && focusIndicator.marksBorder
        let dims = dimsInactive || (!drawsLines && focusIndicator == .border) || ringless
        return (dims ? inactivePaneDimming : 0, .pane)
    }
}
