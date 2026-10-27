public import AppKit

extension StatusIndicatorView {
    /// A loading spinner for chrome (the palette's search bar, sidebar notices, a remote pane's
    /// connecting card) in place of `NSProgressIndicator`, whose spokes are the appearance's gray
    /// whatever the room's theme. It draws the configured loading glyph (the arc by default), the same
    /// one tabs, rows and hover cards draw, in the scope's loading ink (`Palette.textSecondary`, or `appearance.statusIndicator.color`) at its slot's size, stills
    /// under Reduce Motion, turns only while its visibility node is visible (it may be installed
    /// before the window shows), and VoiceOver reads it as a busy indicator while it spins, as AppKit's.
    public static func spinner() -> StatusIndicatorView {
        let view = StatusIndicatorView(frame: .zero)
        view.ignoresScaleSetting = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.busyIndicator)
        return view
    }

    /// Shows the spinner (`spinning`) or hides it. It draws the configured loading style, the
    /// same glyph as every tab, row and hover card spinner, on the shared clock.
    public func spin(_ spinning: Bool) {
        configure(spinning ? .busy : .idle)
    }
}
