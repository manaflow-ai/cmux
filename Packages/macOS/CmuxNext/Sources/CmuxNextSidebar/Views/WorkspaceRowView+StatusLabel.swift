import AppKit
import CmuxNextDesign

/// The static look (`appearance.statusIndicator.animation: "static"`, or
/// Reduce Motion; cx-sya4n): the row names its state in a word or two left of
/// the still mark, in the second line's font and color. It is one more mark
/// of the trailing cluster: the title keeps its place and only ends sooner,
/// and the hover actions fade it out with the marks they cover.
extension WorkspaceRowView {
    /// The longest the label may get; a longer translation truncates.
    static let statusLabelMaxWidth: CGFloat = 96

    /// Lays out the status mark (when `shown`) and, in the static look, its
    /// label left of it, ending at `trailing`; returns the new trailing edge.
    func layoutActivity(trailing: CGFloat, titleTop: CGFloat, line: CGFloat, shown: Bool) -> CGFloat {
        let text = shown && StatusIndicatorAppearance.shared.config.isStatic ? activity.state.shortLabel : nil
        statusLabel.isHidden = text == nil
        guard shown else { return trailing }
        activity.frame = statusGlyphFrame(trailing: trailing, titleTop: titleTop)
        let end = activity.frame.minX - Metrics.space2
        guard let text else { return end }
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
        let width = min(ceil(statusLabel.intrinsicContentSize.width), Self.statusLabelMaxWidth)
        statusLabel.frame = NSRect(x: end + Metrics.space1 - width, y: activity.frame.midY - line / 2, width: width, height: line)
        return statusLabel.frame.minX - Metrics.space2
    }
}
