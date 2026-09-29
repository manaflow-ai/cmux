import AppKit
import CmuxNextDesign

/// Glass highlight showing where a dragged tab will land.
final class DropHighlightView: NSView {
    private let glass: NSGlassEffectView
    private let label = NSTextField(labelWithString: "")
    private var frameSpring = AnimatedFrame(.zero, alpha: 0)
    private(set) var isShowing = false

    override init(frame frameRect: NSRect) {
        let content = NSView()
        glass = Glass.makePanel(content: content, style: .clear, cornerRadius: 10)
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.textPrimary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 6),
        ])
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Moves the highlight to `rect` (superview coordinates). Returns true if
    /// an animation frame is needed.
    func show(_ rect: CGRect, text: String, animated: Bool) -> Bool {
        let rect = rect.insetBy(dx: 4, dy: 4)
        label.stringValue = text
        label.isHidden = text.isEmpty || rect.width < 90
        if !isShowing {
            isShowing = true
            isHidden = false
            let start = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.03)
            frameSpring = AnimatedFrame(start, alpha: animated ? 0 : 1)
        }
        frameSpring.setTarget(rect, alpha: 1)
        if !animated { frameSpring.snap() }
        apply()
        return animated
    }

    func hide(animated: Bool) -> Bool {
        guard isShowing else { return false }
        isShowing = false
        frameSpring.alpha.target = 0
        if !animated {
            frameSpring.snap()
            apply()
            return false
        }
        return true
    }

    func step(_ dt: Double) -> Bool {
        let moving = frameSpring.advance(dt, parameters: .highlight)
        apply()
        return moving
    }

    private func apply() {
        frame = frameSpring.rect
        alphaValue = frameSpring.alpha.value
        if !isShowing && frameSpring.alpha.value <= 0.001 { isHidden = true }
    }
}
