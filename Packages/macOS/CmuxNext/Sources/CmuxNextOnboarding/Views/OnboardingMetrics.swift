import AppKit
import CmuxNextDesign

/// Sizes and type for the onboarding window: one calm size, system font.
enum OnboardingMetrics {
    static let windowSize = NSSize(width: 640, height: 520)
    /// Margin around everything.
    static let margin: CGFloat = 40
    /// Top of the title (below the close button).
    static let titleTop: CGFloat = 52
    static let footerHeight: CGFloat = 64
    static let previewCornerRadius: CGFloat = 10
    static var titleFont: NSFont { .systemFont(ofSize: 22, weight: .semibold) }
    static var bodyFont: NSFont { .systemFont(ofSize: 13) }
    static var captionFont: NSFont { .systemFont(ofSize: 11) }
}

/// Label factory: non-editable, theme colors, wraps when `lines` is not 1.
enum OnboardingLabel {
    static func make(_ text: String = "", font: NSFont = OnboardingMetrics.bodyFont, color: NSColor = Palette.textPrimary, lines: Int = 1) -> NSTextField {
        let label = lines == 1 ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
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

/// Re-runs `render` whenever an observable property it read changes;
/// changes in one main-actor turn coalesce into one render.
@MainActor
final class RenderLoop {
    private let render: () -> Void
    private var active = true

    init(_ render: @escaping () -> Void) {
        self.render = render
        arm()
    }

    func cancel() { active = false }

    private func arm() {
        guard active else { return }
        withObservationTracking(render) { [weak self] in
            Task { @MainActor in self?.arm() }
        }
    }
}
