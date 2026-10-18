import AppKit

/// One agent session line inside a sidebar workspace row: state dot, title
/// (up to two lines), a fixed-width age column, and an optional last-prompt
/// line. Owns its click (swallowed from the table row action) and focuses the
/// session's pane.
@MainActor
final class SidebarRowAgentSessionLine: NSControl {
    var onClick: (() -> Void)?

    static let dotSide: CGFloat = 6
    private static let dotGap: CGFloat = 6
    private static let ageGap: CGFloat = 6
    private static let promptSpacing: CGFloat = 1

    private let dotView = NSView()
    private let titleView = SidebarRowTextView(lines: 2)
    private let ageView = SidebarRowTextView(lines: 1)
    private let promptView = SidebarRowTextView(lines: 1)
    private var ageColumnWidth: CGFloat = 0
    private var titleFont: NSFont = .systemFont(ofSize: 10.5)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = Self.dotSide / 2
        addSubview(dotView)
        addSubview(titleView)
        ageView.alignment = .right
        addSubview(ageView)
        promptView.isHidden = true
        addSubview(promptView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func dotColor(for state: SidebarAgentSessionSnapshot.State) -> NSColor {
        switch state {
        case .running: return NSColor(hex: "#e3b341") ?? .systemYellow
        case .idle: return NSColor(hex: "#39d353") ?? .systemGreen
        case .needsInput: return NSColor(hex: "#f85149") ?? .systemRed
        }
    }

    /// The age column is sized for the widest template so a ticking age never
    /// moves the title or changes the line's height.
    static func ageColumnWidth(font: NSFont) -> CGFloat {
        let widest = SidebarAgentSessionAgeFormatter.columnTemplates
            .map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(widest) + 2
    }

    func configure(
        _ display: SidebarRowAgentSessionDisplay,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        titleFont = .systemFont(ofSize: model.scaled(10.5), weight: .medium)
        let ageFont = NSFont.monospacedDigitSystemFont(ofSize: model.scaled(9.5), weight: .regular)
        dotView.layer?.backgroundColor = Self.dotColor(for: display.state).cgColor
        titleView.stringValue = display.title
        titleView.font = titleFont
        titleView.textColor = palette.secondary(0.92, inactiveOpacity: 0.95)
        ageView.stringValue = display.ageText
        ageView.font = ageFont
        ageView.textColor = palette.secondary(0.62, inactiveOpacity: 0.7)
        ageColumnWidth = Self.ageColumnWidth(font: ageFont)
        promptView.isHidden = display.promptLine == nil
        if let promptLine = display.promptLine {
            promptView.stringValue = promptLine
            promptView.font = .systemFont(ofSize: model.scaled(9.5))
            promptView.textColor = palette.secondary(0.55, inactiveOpacity: 0.6)
        }
        toolTip = display.toolTip
        setAccessibilityLabel(display.accessibilityLabel)
        setAccessibilityIdentifier("sidebarAgentSession.\(display.panelId.uuidString)")
        needsLayout = true
    }

    func resetForReuse() {
        onClick = nil
        toolTip = nil
        titleView.stringValue = ""
        ageView.stringValue = ""
        promptView.stringValue = ""
        promptView.isHidden = true
        alphaValue = 1
    }

    private var titleWidth: CGFloat {
        max(10, bounds.width - Self.dotSide - Self.dotGap - ageColumnWidth - Self.ageGap)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let titleWidth = max(10, width - Self.dotSide - Self.dotGap - ageColumnWidth - Self.ageGap)
        var height = titleView.measuredHeight(width: titleWidth)
        if !promptView.isHidden {
            height += Self.promptSpacing + promptView.measuredHeight(width: max(10, width - Self.dotSide - Self.dotGap))
        }
        return height
    }

    override func layout() {
        super.layout()
        let titleHeight = titleView.measuredHeight(width: titleWidth)
        let firstLineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let firstLineCenter = firstLineHeight / 2
        dotView.frame = NSRect(
            x: 0, y: firstLineCenter - Self.dotSide / 2,
            width: Self.dotSide, height: Self.dotSide
        )
        let titleX = Self.dotSide + Self.dotGap
        titleView.frame = NSRect(x: titleX, y: 0, width: titleWidth, height: titleHeight)
        let ageHeight = ageView.sidebarNaturalCellSize.height
        ageView.frame = NSRect(
            x: bounds.width - ageColumnWidth, y: firstLineCenter - ageHeight / 2,
            width: ageColumnWidth, height: ageHeight
        )
        if !promptView.isHidden {
            let promptWidth = max(10, bounds.width - titleX)
            let promptHeight = promptView.measuredHeight(width: promptWidth)
            promptView.frame = NSRect(
                x: titleX, y: titleHeight + Self.promptSpacing,
                width: promptWidth, height: promptHeight
            )
        }
    }

    // Swallow the press so the table row action does not also fire, dim while
    // pressed like the checklist summary line, fire on release inside bounds.
    override func mouseDown(with event: NSEvent) {
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
