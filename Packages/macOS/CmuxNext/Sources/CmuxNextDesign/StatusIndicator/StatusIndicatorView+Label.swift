import AppKit

extension StatusIndicatorView {
    /// The state's short name as the tooltip and the VoiceOver label, in every look (cx-sya4n),
    /// so a mark never says what it means by color or motion alone.
    func nameState() {
        let label = state.shortLabel
        if themedToolTip != label { themedToolTip = label }
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
    }
}
