// cmux: Reply to Selection's card on the message box (plans/cmux-next/reply-to-selection-DESIGN.md). Not a vendored file.
import AppKit

/// The quote a reply answers, on the message box while the reply is written: a
/// thin neutral bar, "Replying to <name>", the excerpt in two lines at most,
/// and a remove button. The field's own glass; no accent colour.
final class ReplyQuoteCardView: NSView {
    static let gap: CGFloat = 6
    private static let pad = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 8)

    private let glass = LabGlass.surface()
    private let bar = NSView()
    private let title = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let remove = NSButton()
    /// The remove button's action.
    var onRemove: () -> Void = {}

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glass)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        title.font = HomeFonts.system(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        excerpt.font = HomeFonts.system(ofSize: 13)
        excerpt.textColor = .labelColor
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        remove.isBordered = false
        remove.bezelStyle = .regularSquare
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: CmuxStrings.replyQuoteRemove)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = CmuxStrings.replyQuoteRemove
        remove.setAccessibilityLabel(CmuxStrings.replyQuoteRemove)
        remove.target = self
        remove.action = #selector(removeClicked)
        for v in [bar, title, excerpt, remove] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    @objc private func removeClicked() { onRemove() }

    /// Right-click: Copy the quoted words, and Remove Quote.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        HomeContentMenu().textItems(excerpt.stringValue, selection: nil).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: CmuxStrings.replyQuoteRemove, symbol: "xmark.circle") { [weak self] in self?.onRemove() })
        return menu
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { bar.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor }
    }

    /// Shows `quote` from `name` (nil: no name line).
    func show(_ quote: ReplyQuote, from name: String?) {
        title.stringValue = name.map(CmuxStrings.replyingTo) ?? CmuxStrings.replyingToSelection
        excerpt.stringValue = ReplyQuote.excerpt(quote.text, limit: ReplyQuote.cardLimit)
        setAccessibilityLabel(title.stringValue + ": " + excerpt.stringValue)
        effectiveAppearance.performAsCurrentDrawingAppearance { bar.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        needsLayout = true
    }

    /// The card's height at `width`.
    func height(width: CGFloat) -> CGFloat {
        let p = Self.pad
        let textWidth = max(40, width - p.left - 3 - 8 - 22 - p.right)
        let ex = excerpt.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 40)).height ?? 17
        return ceil(p.top + 14 + 1 + min(ex, 36) + p.bottom)
    }

    override func layout() {
        super.layout()
        let p = Self.pad, b = bounds
        glass.frame = b
        glass.cornerRadius = 12
        bar.frame = CGRect(x: p.left, y: p.top, width: 3, height: b.height - p.top - p.bottom)
        let x = bar.frame.maxX + 8
        let w = max(40, b.width - x - 22 - p.right)
        title.frame = CGRect(x: x, y: p.top, width: w, height: 14)
        excerpt.frame = CGRect(x: x, y: p.top + 15, width: w, height: b.height - p.top - 15 - p.bottom)
        remove.frame = CGRect(x: b.width - p.right - 18, y: (b.height - 18) / 2, width: 18, height: 18)
    }
}
