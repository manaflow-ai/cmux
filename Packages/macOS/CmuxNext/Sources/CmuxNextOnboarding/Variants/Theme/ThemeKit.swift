import AppKit
import CmuxNextDesign

/// Helpers the Theme variants share. Selecting goes through
/// `ThemeStepModel.select`, which applies the theme to the app at once.
@MainActor
enum ThemeKit {
    static func name(_ choice: ThemeChoice) -> String { OnboardingStrings.themeName(choice) }

    /// Dark when the background is dim; drives the Dark/Light columns.
    static func isDark(_ input: ThemeInput) -> Bool { input.background.relativeLuminance < 0.3 }

    /// ANSI color `index` of a theme, or its foreground when the theme has fewer.
    static func color(_ input: ThemeInput, _ index: Int?) -> NSColor {
        guard let index, input.palette.indices.contains(index) else { return input.foreground.nsColor }
        return input.palette[index].nsColor
    }

    /// A theme's own hairline: its foreground, faint, so a tile in a
    /// background like the window's still shows its edge.
    static func edge(_ input: ThemeInput) -> NSColor { input.foreground.nsColor.withAlphaComponent(0.14) }

    /// Moves the selection `offset` places, wrapping.
    static func step(_ model: ThemeStepModel, by offset: Int) {
        let choices = model.choices
        guard let index = choices.firstIndex(where: { $0.id == model.selectedChoice.id }), !choices.isEmpty else { return }
        model.select(choices[(index + offset + choices.count) % choices.count].name)
    }
}

/// One pickable theme in a `ThemeChoiceStack`.
@MainActor
protocol ThemeChoiceItem: NSView {
    var onPress: (() -> Void)? { get set }
    func show(_ choice: ThemeChoice, selected: Bool)
}

/// A clickable, drawn view: a press fires on mouse-up inside, or through
/// Accessibility. Never drags the window (the onboarding window moves by
/// its background).
class ThemePressable: NSView {
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    // Keyboard: Tab reaches each item (Full Keyboard Access), Space or
    // Return picks it, and the system draws the focus ring.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: onPress?()   // Space, Return, Enter
        default: super.keyDown(with: event)
        }
    }
}
