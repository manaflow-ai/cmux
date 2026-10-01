import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The inline shortcut recorder over the palette's list: the action, its
/// current shortcut, the chord just pressed, why it cannot be saved or what
/// it collides with, and the choices with their keys. A small glass panel
/// like the Actions menu; rebuilt on each change (a handful of rows).
final class PaletteShortcutRecorderView: NSView {
    var onChoose: ((PaletteShortcutOption) -> Void)?

    private let glass = Glass.makePanel(cornerRadius: PaletteLayout.cornerRadius)
    private let content = FlippedView()
    private let title = PaletteText.label(Typography.header, tone: .secondary)
    private let action = PaletteText.label(Typography.bodyEmphasized)
    private let current = PaletteKeycapsView()
    private let noneLabel = PaletteText.label(Typography.caption, tone: .tertiary)
    private let recorded = PaletteKeycapsView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var rowViews: [PaletteMenuRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.contentView = content
        message.font = Typography.body
        message.maximumNumberOfLines = 4
        title.stringValue = PaletteStrings.recorderTitle
        noneLabel.stringValue = PaletteStrings.noShortcut
        [title, action, current, noneLabel, recorded, message].forEach(content.addSubview)
        addSubview(glass)
        setAccessibilityIdentifier("cmux.commandPalette.shortcutRecorder")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            glass.tintColor = Palette.glassTint
            message.textColor = Palette.textSecondary
        }
    }

    static var messageHeight: CGFloat { Typography.body.pointSize * 1.3 * 3 }

    /// Height the panel wants for `state`.
    static func height(for state: PaletteShortcutRecorderState) -> CGFloat {
        Metrics.space4 + PaletteLayout.headerRowHeight + PaletteLayout.rowHeight + PaletteLayout.keycapSize + Metrics.space4
            + messageHeight + Metrics.space2 + CGFloat(state.options.count) * PaletteLayout.actionsMenuRowHeight + Metrics.space4
    }

    func update(_ state: PaletteShortcutRecorderState) {
        action.stringValue = state.actionTitle
        current.keycaps = state.currentKeycaps ?? []
        current.isHidden = state.currentKeycaps == nil
        noneLabel.isHidden = state.currentKeycaps != nil
        recorded.keycaps = state.recorded?.keycaps ?? []
        recorded.isHidden = state.recorded == nil
        message.stringValue = state.message ?? ""
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = state.options.enumerated().map { index, option in
            let row = PaletteMenuRow(command: Self.command(option), keycaps: Self.keycaps(option), isSelected: index == 0 && state.pending != nil)
            row.onClick = { [weak self] in self?.onChoose?(option) }
            content.addSubview(row)
            return row
        }
        needsLayout = true
    }

    private static func command(_ option: PaletteShortcutOption) -> PaletteCommand {
        let (title, symbol): (String, String) = switch option {
        case .save: (PaletteStrings.optionSave, "checkmark")
        case .replace: (PaletteStrings.optionReplace, "arrow.triangle.swap")
        case .keepBoth: (PaletteStrings.optionKeepBoth, "square.on.square")
        case .cancel: (PaletteStrings.optionCancel, "xmark")
        case .remove: (PaletteStrings.optionRemove, "minus.circle")
        case .restoreDefault: (PaletteStrings.optionRestoreDefault, "arrow.counterclockwise")
        }
        return PaletteCommand(id: title, title: title, symbol: symbol, effect: .performKeepingOpen {})
    }

    private static func keycaps(_ option: PaletteShortcutOption) -> [String] {
        switch option {
        case .save, .replace: ["↩"]
        case .keepBoth: ["⌥", "↩"]
        case .cancel: ["⎋"]
        case .remove: ["⌫"]
        case .restoreDefault: ["⇧", "⌫"]
        }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let padding = PaletteLayout.horizontalPadding
        let width = bounds.width - 2 * padding
        var y = Metrics.space4
        title.frame = NSRect(x: padding, y: y, width: width, height: title.intrinsicContentSize.height)
        y += PaletteLayout.headerRowHeight
        let actionHeight = action.intrinsicContentSize.height
        let currentSize = current.isHidden ? CGSize(width: PaletteText.fittingWidth(noneLabel), height: noneLabel.intrinsicContentSize.height)
            : current.intrinsicContentSize
        let right = bounds.width - padding - currentSize.width
        action.frame = NSRect(x: padding, y: y + (PaletteLayout.rowHeight - actionHeight) / 2, width: max(0, right - padding - Metrics.space4),
                              height: actionHeight)
        let currentFrame = NSRect(x: right, y: y + (PaletteLayout.rowHeight - currentSize.height) / 2, width: currentSize.width,
                                  height: currentSize.height)
        current.frame = currentFrame
        noneLabel.frame = currentFrame
        y += PaletteLayout.rowHeight
        let recordedSize = recorded.intrinsicContentSize
        recorded.frame = NSRect(x: (bounds.width - recordedSize.width) / 2, y: y, width: recordedSize.width, height: recordedSize.height)
        y += PaletteLayout.keycapSize + Metrics.space4
        message.preferredMaxLayoutWidth = width
        message.frame = NSRect(x: padding, y: y, width: width, height: Self.messageHeight)
        y += Self.messageHeight + Metrics.space2
        for row in rowViews {
            row.frame = NSRect(x: Metrics.space2, y: y, width: bounds.width - 2 * Metrics.space2, height: PaletteLayout.actionsMenuRowHeight)
            y += PaletteLayout.actionsMenuRowHeight
        }
    }
}
