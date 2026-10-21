import AppKit
import CmuxNextDesign

/// "Sized for <device> · 118×38" with Take over, in the bottom-trailing corner of a terminal whose grid another view
/// sets and does not fit this one (plans/cmux-next/sync-ux/DESIGN.md 2.6). The grid stays where the
/// owner put it (padded or cropped by the host); the chip says why, and Take over gives this view
/// the grid: a new claim, after setting the terminal to last active when its policy picks by size
/// or rank. Hidden while this view sets the grid or the grid fits it. Styled like
/// ``TerminalStatusBanner``; only the button takes clicks.
final class TerminalSizedForChip: NSView {
    private let label = ThemedLabel(labelWithString: "")
    private let button: NSButton
    private let stack = NSStackView()
    /// Called with ``TerminalSizedFor/takeOverSetsLatest`` of the shown notice.
    var onTakeOver: (@MainActor (Bool) -> Void)?
    private(set) var shown: TerminalSizedFor?

    init() {
        let title = ModuleResourceBundle.terminal.text("terminal.sizedFor.takeOver", defaultValue: "Take over")
        button = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = #selector(takeOver)
        stack.setViews([label, button], in: .leading)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    private func applyThemeColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            button.contentTintColor = Palette.textSecondary
            button.bezelColor = Palette.selectionFill
        }
    }

    /// Only Take over is a target; the rest of the chip lets clicks reach the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === button && !button.isHidden ? hit : nil
    }

    /// Shows `sizedFor` (nil hides it). It fades in on `fadeIn` when it appears; a later change
    /// of owner or grid only changes the text.
    func show(_ sizedFor: TerminalSizedFor?) {
        shown = sizedFor
        guard let sizedFor else {
            isHidden = true
            return
        }
        let text = Self.text(for: sizedFor)
        label.stringValue = text
        setAccessibilityLabel(text)
        if isHidden, let layer {
            let seconds = Motion.overlays.duration(.fadeIn)
            if seconds > 0 {
                // motion-allow: a fade on Motion's .fadeIn duration and fadeCurve, skipped when Motion says 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = seconds
                fade.timingFunction = Motion.fadeCurve
                layer.add(fade, forKey: "terminalSizedFor.reveal")
            }
        }
        isHidden = false
    }

    @objc private func takeOver() {
        guard let shown else { return }
        onTakeOver?(shown.takeOverSetsLatest)
    }

    /// "Sized for Maya's iPhone · 54×44", "Sized for another window · 150×42".
    static func text(for sizedFor: TerminalSizedFor, strings: ModuleResourceBundle = .terminal) -> String {
        let cols = sizedFor.grid.columns
        let rows = sizedFor.grid.rows
        if sizedFor.fixedSize {
            return strings.text("terminal.sizedFor.fixed", defaultValue: "Fixed size · \(cols)×\(rows)")
        }
        if sizedFor.sameDevice {
            return strings.text("terminal.sizedFor.anotherWindow", defaultValue: "Sized for another window · \(cols)×\(rows)")
        }
        let name = deviceName(sizedFor, strings: strings)
        return strings.text("terminal.sizedFor", defaultValue: "Sized for \(name) · \(cols)×\(rows)")
    }

    /// The owner's own name, else its kind (product names are not translated), else "another device".
    private static func deviceName(_ sizedFor: TerminalSizedFor, strings: ModuleResourceBundle) -> String {
        if let name = sizedFor.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch sizedFor.deviceKind {
        case "iphone": return "iPhone"
        case "ipad": return "iPad"
        case "mac": return "Mac"
        default: return strings.text("terminal.sizedFor.anotherDevice", defaultValue: "another device")
        }
    }
}
