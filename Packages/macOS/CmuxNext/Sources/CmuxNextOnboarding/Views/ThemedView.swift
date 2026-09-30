import AppKit
import CmuxNextDesign

/// A layer-backed view whose colors come from closures, re-resolved when
/// the theme (appearance) changes. Base class for small chrome pieces.
class ThemedView: NSView {
    var fill: () -> NSColor? = { nil } { didSet { applyColors() } }
    var border: () -> NSColor? = { nil } { didSet { applyColors() } }
    var borderWidth: CGFloat = 1 { didSet { applyColors() } }
    var cornerRadius: CGFloat = 0 { didSet { layer?.cornerRadius = cornerRadius } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyColors() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        layer?.backgroundColor = fill()?.cgColor
        let stroke = border()
        layer?.borderColor = stroke?.cgColor
        layer?.borderWidth = stroke == nil ? 0 : borderWidth
    }
}

/// Five short bars: done, current, ahead.
final class StepProgressView: NSView {
    private var bars: [ThemedView] = []
    var current = 0 { didSet { update(animated: true) } }

    init(count: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<count {
            let bar = ThemedView()
            bar.cornerRadius = 1.5
            bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
            bar.widthAnchor.constraint(equalToConstant: Metrics.space6 + Metrics.space2).isActive = true
            bars.append(bar)
            stack.addArrangedSubview(bar)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        update(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update(animated: Bool) {
        for (index, bar) in bars.enumerated() {
            let color: () -> NSColor = index == current ? { Palette.textPrimary } : index < current ? { Palette.textTertiary } : { Palette.selectionFill }
            if animated, let layer = bar.layer {
                Motion.set(layer, "backgroundColor", to: color().cgColor, fade: .focus)
            }
            bar.fill = color
        }
        setAccessibilityValue("\(current + 1)/\(bars.count)")
    }
}

/// A key cap for shortcut display ("⇧⌘P" becomes one cap per glyph).
final class KeycapView: ThemedView {
    init(_ text: String) {
        super.init(frame: .zero)
        fill = { Palette.hoverFill }
        border = { Palette.separator }
        cornerRadius = Metrics.space2 + 1
        let label = OnboardingLabel.make(text, font: Typography.shortcut, color: Palette.textSecondary)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.space6 + Metrics.space3),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: Metrics.space4),
        ])
        let hug = widthAnchor.constraint(equalTo: label.widthAnchor, constant: Metrics.space4)
        hug.priority = .hugsInStack
        hug.isActive = true
    }

    /// One cap per modifier glyph plus one for the key ("⇧⌘P" -> ⇧ ⌘ P).
    static func caps(for shortcut: String) -> NSStackView {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var key = ""
        for character in shortcut {
            if modifiers.contains(character), key.isEmpty { parts.append(String(character)) } else { key.append(character) }
        }
        if !key.isEmpty { parts.append(key) }
        let stack = NSStackView(views: parts.map { KeycapView($0) })
        stack.spacing = Metrics.space1 + 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

