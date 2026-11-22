import AppKit
import CmuxNextDesign

/// Type for the native onboarding panels (the helper drag panel): system font.
enum OnboardingMetrics {
    /// The type scale's steps, so every panel follows Interface Size.
    static var bodyFont: NSFont { Typography.system(size: TypeScale.body) }
}

extension OnboardingModel.Step {
    /// The tool window's fixed content size: one calm size, a smaller one for Computer Use.
    var windowSize: NSSize {
        self == .computerUse ? NSSize(width: 520, height: 480) : NSSize(width: 640, height: 520)
    }
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
