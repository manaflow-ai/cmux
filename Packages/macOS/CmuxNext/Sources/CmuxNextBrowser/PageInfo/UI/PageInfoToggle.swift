import AppKit
import CmuxNextDesign
import QuartzCore

/// The permission toggle, in theme grays: the track is the foreground
/// when on (no accent color) and a faint fill when off.
final class PageInfoToggle: NSView {
    var onChange: ((Bool) -> Void)?

    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            refresh(animated: window != nil)
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    private let track = CALayer()
    private let knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.shadowOpacity = 0.18
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(0)
        translatesAutoresizingMaskIntoConstraints = false
        refresh(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { PageInfoStyle.toggleSize }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    private func refresh(animated: Bool) {
        // The knob slides with the selection token (instant under Reduce
        // Motion or when animations are off).
        guard animated else { return Motion.transaction(nil) { applyState() } }
        Motion.transaction(spring: .selection) { applyState() }
    }

    private func applyState() {
        let size = bounds.size == .zero ? PageInfoStyle.toggleSize : bounds.size
        track.frame = CGRect(origin: .zero, size: size)
        track.cornerRadius = size.height / 2
        let inset: CGFloat = 2
        let diameter = size.height - inset * 2
        knob.frame = CGRect(x: isOn ? size.width - inset - diameter : inset, y: inset, width: diameter, height: diameter)
        knob.cornerRadius = diameter / 2
        performWithTheme {
            track.backgroundColor = (isOn ? PageInfoStyle.text : PageInfoStyle.pressed).cgColor
            knob.backgroundColor = (isOn ? PageInfoStyle.background : PageInfoStyle.secondaryText).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    func flip() {
        isOn.toggle()
        onChange?(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }
}
