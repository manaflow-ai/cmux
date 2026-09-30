import AppKit
import CmuxNextDesign

/// Sizes for the onboarding window, derived from the design tokens so they
/// follow density.
enum OnboardingMetrics {
    static var compact: Bool { Metrics.density == .compact }
    static var windowSize: NSSize { compact ? NSSize(width: 760, height: 540) : NSSize(width: 840, height: 600) }
    /// Side inset of titles and step content.
    static var contentInset: CGFloat { Metrics.space6 * 3 }
    static var titleTop: CGFloat { Metrics.titlebarHeight + Metrics.space5 }
    static var footerHeight: CGFloat { Metrics.space6 * 3.5 }
    static var buttonHeight: CGFloat { compact ? 28 : 32 }
    static var rowHeight: CGFloat { compact ? 34 : 40 }
    static var themeCardSize: NSSize { compact ? NSSize(width: 112, height: 72) : NSSize(width: 124, height: 80) }
    static var cornerRadius: CGFloat { Metrics.panelCornerRadius }
    static var itemRadius: CGFloat { Metrics.itemCornerRadius }
    /// Distance a step slides in from.
    static let slideDistance: CGFloat = 18
}

/// Label factory: non-editable, theme colors, wraps when `lines` is not 1.
enum OnboardingLabel {
    static func make(_ text: String = "", font: NSFont = Typography.body, color: NSColor = Palette.textPrimary, lines: Int = 1) -> NSTextField {
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
