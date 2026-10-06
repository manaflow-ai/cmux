import AppKit
import CmuxNextDesign

/// Shared controls for onboarding actions and choices.
enum OnboardingControl {
    static func button(_ title: String, prominent: Bool = false, accent: Bool = false, target: AnyObject?, action: Selector) -> NSButton {
        if accent { return OnboardingAccentButton(title: title, target: target, action: action) }
        let button = NSButton(title: title, target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = prominent ? .glass : .push
        button.controlSize = .large
        button.bezelColor = prominent ? Palette.selectionFill : nil
        return button
    }

    /// Secondary text with a hover fill (`OnboardingTextButton`).
    static func plainButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        OnboardingTextButton(title, target: target, action: action)
    }

    static func checkbox(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentTintColor = Palette.textPrimary
        box.bezelColor = Palette.textPrimary
        box.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: OnboardingMetrics.bodyFont, .foregroundColor: Palette.textPrimary,
        ])
        singleLine(box)
        return box
    }

    static func radio(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let radio = NSButton(radioButtonWithTitle: title, target: target, action: action)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.contentTintColor = Palette.textPrimary
        radio.bezelColor = Palette.textPrimary
        radio.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: OnboardingMetrics.bodyFont, .foregroundColor: Palette.textPrimary,
        ])
        singleLine(radio)
        return radio
    }

    /// Titles stay on one line at their full width (a squeezed stack made
    /// AppKit wrap "Bookmarks" into "Bookmark/s").
    private static func singleLine(_ button: NSButton) {
        button.cell?.wraps = false
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
}
