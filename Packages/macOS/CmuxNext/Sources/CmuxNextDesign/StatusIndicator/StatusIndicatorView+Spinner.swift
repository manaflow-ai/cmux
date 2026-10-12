public import AppKit

extension StatusIndicatorView {
    /// A loading spinner for chrome (the palette's search bar, sidebar notices, a remote pane's
    /// connecting card) in place of `NSProgressIndicator`, whose spokes are the appearance's gray
    /// whatever the room's theme. It draws the native spokes in the scope's loading ink
    /// (`Palette.textSecondary`, or `appearance.statusIndicator.color`), stills under Reduce
    /// Motion, and VoiceOver reads it as a progress indicator while it spins.
    public static func spinner() -> StatusIndicatorView {
        let view = StatusIndicatorView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.progressIndicator)
        return view
    }

    /// Shows the spinner (`spinning`) or hides it.
    public func spin(_ spinning: Bool) {
        configure(spinning ? .busy : .idle, style: .native)
    }
}
