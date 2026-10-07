import AppKit
import CmuxNextDesign

/// One option row: number keycap, label, description and a checkmark. It
/// is an accessibility radio button (single select) or checkbox (multi).
final class AgentQuestionOptionRowView: NSView {
    struct Content: Equatable {
        var number: Int
        var count: Int
        var label: String
        var detail: String?
        var chosen: Bool
        var highlighted: Bool
        var multiSelect: Bool
        var isOther: Bool
        var enabled: Bool
    }

    var onClick: (() -> Void)?
    private(set) var content: Content?
    private let keycap = CALayer()
    private let keycapLabel = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private var frames: AgentQuestionCardLayout.Row?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.addSublayer(keycap)
        keycap.cornerCurve = .continuous
        for label in [keycapLabel, title, detail] {
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            addSubview(label)
        }
        keycapLabel.alignment = .center
        check.imageScaling = .scaleProportionallyUpOrDown
        addSubview(check)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // crash-allow: never decoded from a nib

    func configure(_ content: Content, frames: AgentQuestionCardLayout.Row, style: AgentQuestionCardStyle) {
        self.content = content
        // Frames arrive in card coordinates; the row lays out relative to its origin.
        let origin = frames.frame.origin
        let local = { (rect: CGRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        self.frames = AgentQuestionCardLayout.Row(frame: frames.frame, keycap: local(frames.keycap), label: local(frames.label),
                                                  detail: frames.detail.map(local), check: local(frames.check), isOther: frames.isOther)
        layer?.cornerRadius = style.size(9)
        keycap.cornerRadius = style.size(5)
        keycapLabel.font = style.keycapFont
        keycapLabel.stringValue = content.number <= 9 ? "\(content.number)" : ""
        title.font = style.labelFont
        title.stringValue = content.label
        detail.font = style.detailFont
        detail.stringValue = content.detail ?? ""
        detail.isHidden = content.detail == nil
        let symbol = content.multiSelect ? (content.chosen ? "checkmark.square.fill" : "square") : "checkmark"
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        check.isHidden = !content.multiSelect && !content.chosen
        applyColors()
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(content.multiSelect ? .checkBox : .radioButton)
        setAccessibilityLabel([content.label, content.detail].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(content.chosen ? 1 : 0)
        setAccessibilityHelp(AgentQuestionStrings().optionPosition(content.number, of: content.count))
        setAccessibilityEnabled(content.enabled)
    }

    override func layout() {
        super.layout()
        guard let frames else { return }
        keycap.frame = frames.keycap
        let labelHeight = keycapLabel.intrinsicContentSize.height
        keycapLabel.frame = CGRect(x: frames.keycap.minX, y: frames.keycap.midY - labelHeight / 2,
                                   width: frames.keycap.width, height: labelHeight)
        title.frame = frames.label
        detail.frame = frames.detail ?? .zero
        check.frame = frames.check
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        guard let content else { return }
        performWithTheme {
            let fill: NSColor = content.highlighted ? Palette.selectionFill : (content.chosen ? Palette.hoverFill : .clear)
            layer?.backgroundColor = fill.cgColor
            keycap.backgroundColor = (content.chosen ? Palette.textPrimary : Palette.hoverFill).cgColor
            keycap.borderColor = Palette.separator.cgColor
            keycap.borderWidth = content.chosen ? 0 : 1
            keycapLabel.textColor = content.chosen ? Palette.windowBackground : Palette.textSecondary
            title.textColor = content.isOther ? Palette.textSecondary : Palette.textPrimary
            detail.textColor = Palette.textSecondary
            check.contentTintColor = content.chosen ? Palette.textPrimary : Palette.textTertiary
            alphaValue = content.enabled ? 1 : 0.5
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard content?.enabled == true else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard content?.enabled == true else { return false }
        onClick?()
        return true
    }
}
