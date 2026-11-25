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
    private let button: TerminalSizedForChipButton
    private let stack = NSStackView()
    /// Called with ``TerminalSizedFor/takeOverSetsLatest`` of the shown notice.
    var onTakeOver: (@MainActor (Bool) -> Void)?
    private(set) var shown: TerminalSizedFor?

    init() {
        let title = ModuleResourceBundle.terminal.text("terminal.sizedFor.takeOver", defaultValue: "Take over")
        button = TerminalSizedForChipButton(title: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = #selector(takeOver)
        stack.setViews([label, button], in: .leading)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        // Take over sits the same gap from the chip's top, bottom and trailing edges.
        let gap = Self.buttonGap
        stack.edgeInsets = NSEdgeInsets(top: gap, left: 10, bottom: gap, right: gap)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: TerminalSizedForChipButton.height + gap * 2),
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
        // The button draws its title and bezel for its own appearance, not the theme's colors: on a
        // dark terminal theme in a light app it drew a dark title on the dark chip. It takes the
        // theme's light or dark appearance, as the chip's fill and label do.
        let dark = themeTokens.isDark
        if Self.isDark(button.appearance) != dark { button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            button.applyColors(fill: Palette.selectionFill, title: Palette.textPrimary,
                               font: .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis))
        }
    }

    override func layout() {
        super.layout()
        let radii = Self.cornerRadii(paneCornerRadius: Self.paneCornerRadius, chipInset: Metrics.panelInset,
                                     chipHeight: bounds.height, buttonGap: Self.buttonGap)
        if layer?.cornerRadius != radii.chip { layer?.cornerRadius = radii.chip }
        if button.cornerRadius != radii.button { button.cornerRadius = radii.button }
    }

    // MARK: Concentric corners

    /// The gap between Take over and the chip's top, bottom and trailing edges.
    static let buttonGap: CGFloat = 3

    /// The corner of the pane the chip sits in, by the window-concentric rule (a1050): a floating
    /// pane's card, else the main pane's corner, concentric with the window across its gutter.
    static var paneCornerRadius: CGFloat {
        Metrics.floatingPanes ? Metrics.floatingPaneCornerRadius
            : Metrics.mainPaneCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius)
    }

    /// The chip's and Take over's radii, each nested in the corner around it: the chip
    /// `chipInset` inside a pane corner of `paneCornerRadius` (at most half its height), Take over
    /// `buttonGap` inside the chip. A 10 pt main pane with a 6 pt inset and a 3 pt gap: 4 and 1.
    static func cornerRadii(paneCornerRadius: CGFloat, chipInset: CGFloat, chipHeight: CGFloat,
                            buttonGap: CGFloat) -> (chip: CGFloat, button: CGFloat) {
        // Each nested radius is the one around it less the gap between them (ConcentricCorners' rule).
        let chip = max(0, min(paneCornerRadius - chipInset, chipHeight / 2))
        return (chip, max(0, chip - buttonGap))
    }

    private static func isDark(_ appearance: NSAppearance?) -> Bool? {
        appearance.map { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
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
