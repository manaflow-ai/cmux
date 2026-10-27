import AppKit
import CmuxNextDesign

/// Sizes and type for the onboarding window: one calm size, system font.
enum OnboardingMetrics {
    static let windowSize = NSSize(width: 640, height: 520)
    /// Margin around everything.
    static let margin: CGFloat = 40
    static var titleFont: NSFont { Typography.system(size: 22, weight: .semibold) }
    static var bodyFont: NSFont { Typography.system(size: 13) }
    static var captionFont: NSFont { Typography.system(size: 11) }
}

/// Label factory: non-editable, theme colors, wraps when `lines` is not 1.
enum OnboardingLabel {
    static func make(_ text: String = "", font: NSFont = OnboardingMetrics.bodyFont, color: NSColor = Palette.textPrimary, lines: Int = 1) -> ChromeLabel {
        let label = lines == 1 ? ChromeLabel(labelWithString: text) : ChromeLabel(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if lines != 1 {
            // Below NSWindow's stay-put priority (500): a long translation
            // wraps or clips inside the fixed window instead of growing it.
            label.setContentCompressionResistancePriority(.init(490), for: .vertical)
        }
        return label
    }
}
