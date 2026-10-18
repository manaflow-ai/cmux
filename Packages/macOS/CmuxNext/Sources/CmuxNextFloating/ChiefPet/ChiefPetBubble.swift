import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The pill above the Chief pet: the newest notice's status mark, title and
/// one line of text, with the notices behind it peeking out below as a deck.
/// A child window of the pet, so it moves with every drag; never key.
final class ChiefPetBubblePanel: NSPanel {
    static let accessibilityID = "cmux.chiefPet.bubble"
    static let width: CGFloat = 300
    static let pillHeight: CGFloat = 52
    /// How far each notice behind the front one peeks out below it.
    static let deckStep: CGFloat = 5
    /// The gap between the deck and the pet.
    static let gap: CGFloat = 6

    var onClick: (() -> Void)?
    let bubble = ChiefPetBubbleView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(depth: 1)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier(Self.accessibilityID)
        bubble.frame = contentLayoutRect
        bubble.autoresizingMask = [.width, .height]
        bubble.onClick = { [weak self] in self?.onClick?() }
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel's height for a deck of `depth` notices (the front one and up to two behind).
    static func height(depth: Int) -> CGFloat {
        pillHeight + deckStep * CGFloat(max(0, min(depth, ChiefPetFeed.limit) - 1))
    }

    /// Centered over `pet`, `gap` above it; below it when the screen's top is too close.
    static func frame(height: CGFloat, over pet: CGRect, in visible: CGRect) -> CGRect {
        var frame = CGRect(x: pet.midX - width / 2, y: pet.maxY + gap, width: width, height: height)
        if frame.maxY > visible.maxY { frame.origin.y = pet.minY - gap - height }
        frame.origin = ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: visible)
        return frame
    }
}

/// The bubble's drawing. `show` redraws only when what it shows changed.
final class ChiefPetBubbleView: NSView {
    var onClick: (() -> Void)?
    private let front = Glass.makeOverlayPanel(cornerRadius: ChiefPetBubblePanel.pillHeight / 2)
    /// The notices behind the front one: bare pills under it, each a step lower and narrower.
    private let deck = [Glass.makeOverlayPanel(cornerRadius: ChiefPetBubblePanel.pillHeight / 2, interactive: false),
                        Glass.makeOverlayPanel(cornerRadius: ChiefPetBubblePanel.pillHeight / 2, interactive: false)]
    private let mark = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    private let detail = ChromeLabel(labelWithString: "")
    /// What it draws now: identical content is never drawn (or animated) again.
    private(set) var shown: (content: [String], depth: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for layer in deck.reversed() {
            layer.translatesAutoresizingMaskIntoConstraints = true
            addSubview(layer)
        }
        front.translatesAutoresizingMaskIntoConstraints = true
        addSubview(front)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            front.contentView.addSubview(label)
        }
        front.contentView.addSubview(mark)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws `notice` with `depth` notices in the deck; false when it already shows exactly that.
    @discardableResult
    func show(_ notice: ChiefPetNotice, depth: Int) -> Bool {
        let depth = min(depth, ChiefPetFeed.limit)
        if let shown, shown.content == notice.content, shown.depth == depth { return false }
        shown = (notice.content, depth)
        title.stringValue = notice.title
        detail.stringValue = notice.detail
        detail.isHidden = notice.detail.isEmpty
        mark.image = NSImage.icon(Self.icon(notice.kind), size: Metrics.statusMarkSize)
        for (index, layer) in deck.enumerated() { layer.isHidden = index >= depth - 1 }
        setAccessibilityLabel([notice.title, notice.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        recolor(kind: notice.kind)
        needsLayout = true
        return true
    }

    static func icon(_ kind: ChiefPetNotice.Kind) -> IconName {
        switch kind {
        case .needsYou: .statusNeedsinput
        case .failed: .statusError
        case .done: .statusComplete
        }
    }

    private var kind: ChiefPetNotice.Kind = .done

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }

    private func recolor(kind: ChiefPetNotice.Kind? = nil) {
        if let kind { self.kind = kind }
        performWithTheme {
            title.textColor = Palette.textPrimary
            title.font = Typography.bodyEmphasized
            detail.textColor = Palette.textSecondary
            detail.font = Typography.body
            mark.contentTintColor = switch self.kind {
            case .needsYou: Palette.attention
            case .failed: Palette.danger
            case .done: Palette.success
            }
        }
    }

    override func layout() {
        super.layout()
        let pill = ChiefPetBubblePanel.pillHeight
        let step = ChiefPetBubblePanel.deckStep
        front.frame = CGRect(x: 0, y: bounds.height - pill, width: bounds.width, height: pill)
        for (index, layer) in deck.enumerated() {
            let inset = CGFloat(index + 1) * 10
            layer.frame = CGRect(x: inset, y: bounds.height - pill - CGFloat(index + 1) * step, width: bounds.width - inset * 2, height: pill)
        }
        let side: CGFloat = 18
        let markSize = Metrics.statusMarkSize
        mark.frame = CGRect(x: side, y: (pill - markSize) / 2, width: markSize, height: markSize)
        let textX = side + markSize + 10
        let textWidth = bounds.width - textX - side
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let detailHeight = detail.isHidden ? 0 : ceil(detail.intrinsicContentSize.height)
        let top = (pill + titleHeight + detailHeight) / 2
        title.frame = CGRect(x: textX, y: top - titleHeight, width: textWidth, height: titleHeight)
        detail.frame = CGRect(x: textX, y: top - titleHeight - detailHeight, width: textWidth, height: detailHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { front.frame.contains(convert(point, from: superview)) ? self : nil }

    override func mouseUp(with event: NSEvent) {
        guard front.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
