import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Observation

/// The panel's list variant in AppKit: the title bar (title, badge, Mark All Read), the rows, and
/// the empty state. The bar reads only ``FeedModel/summary``, which changes only when the badge or
/// the empty state does, so an owner event costs the bar nothing and the rows only their edits
/// (``FeedRowsView``). It replaces a SwiftUI header whose re-evaluation laid out the whole panel
/// on every badge change.
final class FeedListPane: NSView {
    let model: FeedModel
    let rows: FeedRowsView
    private let title = FeedListPane.label(FeedStrings.title, size: TypeScale.body, weight: TypeScale.emphasis)
    private let badge = FeedListPane.label("", size: TypeScale.caption, weight: TypeScale.emphasis)
    private let badgeGround = NSView()
    private let markAll = NSButton()
    private let emptyIcon = NSImageView(image: NSImage.icon(.inboxEmpty, size: 32))
    private let emptyText = FeedListPane.label(FeedStrings.empty, size: TypeScale.detail)
    private var colors = ReportsBasketColors()
    private var armed = false
    private(set) var shown = FeedSummary()

    static let barHeight: CGFloat = 38

    init(model: FeedModel) {
        self.model = model
        rows = FeedRowsView(model: model, mode: .list)
        super.init(frame: .zero)
        badgeGround.wantsLayer = true
        badgeGround.layer?.cornerRadius = 8
        badge.alignment = .center
        markAll.image = NSImage.icon(.actionConfirm, size: 13)
        markAll.image?.isTemplate = true
        markAll.isBordered = false
        markAll.imagePosition = .imageOnly
        markAll.target = self
        markAll.action = #selector(markAllRead)
        markAll.themedToolTip = FeedStrings.markAllRead
        markAll.setAccessibilityLabel(FeedStrings.markAllRead)
        markAll.setAccessibilityIdentifier("cmux.feed.markAllRead")
        emptyIcon.image?.isTemplate = true
        emptyText.alignment = .center
        for view in [title, badgeGround, badge, markAll, rows, emptyIcon, emptyText] as [NSView] { addSubview(view) }
        show(shown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = TypeScale.regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        return label
    }

    override var isFlipped: Bool { true }

    /// The label's width for its text, as its cell draws it (with the cell's own padding); the
    /// field's intrinsic width follows its last frame, so it cannot be used to size that frame.
    private static func width(of label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if armed { show(model.summary) } else { observe() }
    }

    /// Reads the summary in a tracked scope; the next change re-arms only in a window.
    private func observe() {
        guard window != nil else { return }
        armed = true
        withObservationTracking { show(model.summary) } onChange: { [weak self] in
            // task-owner: re-arms one observation; it ends at once when the view left its window or is gone
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armed = false
                self.observe()
            }
        }
    }

    private func show(_ summary: FeedSummary) {
        shown = summary
        let badgeCount = summary.counts.badge
        badge.stringValue = "\(badgeCount)"
        badge.isHidden = badgeCount == 0
        badgeGround.isHidden = badgeCount == 0
        markAll.isEnabled = summary.counts.unreadNotices > 0
        rows.isHidden = summary.listIsEmpty
        emptyIcon.isHidden = !summary.listIsEmpty
        emptyText.isHidden = !summary.listIsEmpty
        needsLayout = true
    }

    @objc private func markAllRead() {
        model.markAllRead()
    }

    func apply(_ colors: ReportsBasketColors) {
        rows.apply(colors)
        guard colors != self.colors else { return }
        self.colors = colors
        title.textColor = colors.primary
        badge.textColor = colors.secondary
        badgeGround.layer?.backgroundColor = colors.hover.cgColor
        markAll.contentTintColor = colors.secondary
        emptyIcon.contentTintColor = colors.tertiary
        emptyText.textColor = colors.tertiary
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 14, bar = Self.barHeight
        // Measured from the text: a truncating label's intrinsic width follows its last frame.
        let titleWidth = Self.width(of: title)
        let titleHeight = ceil(title.font?.boundingRectForFont.height ?? TypeScale.bodyLineHeight)
        title.frame = NSRect(x: side, y: (bar - titleHeight) / 2, width: min(titleWidth, max(0, bounds.width - 2 * side - 60)), height: titleHeight)
        let badgeWidth = max(16, Self.width(of: badge) + 12)
        badgeGround.frame = NSRect(x: title.frame.maxX + 8, y: (bar - 16) / 2, width: badgeWidth, height: 16)
        let badgeHeight = ceil(badge.font?.boundingRectForFont.height ?? TypeScale.captionLineHeight)
        badge.frame = NSRect(x: badgeGround.frame.minX, y: badgeGround.frame.midY - badgeHeight / 2, width: badgeWidth, height: badgeHeight)
        markAll.frame = NSRect(x: bounds.width - side - 20, y: (bar - 20) / 2, width: 20, height: 20)
        let body = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
        rows.frame = body
        let textHeight = ceil(emptyText.font?.boundingRectForFont.height ?? TypeScale.detailLineHeight)
        let middle = body.midY
        emptyIcon.frame = NSRect(x: body.midX - 16, y: middle - 16 - 4 - textHeight / 2, width: 32, height: 32)
        emptyText.frame = NSRect(x: 24, y: emptyIcon.frame.maxY + 8, width: max(0, body.width - 48), height: textHeight)
    }
}
