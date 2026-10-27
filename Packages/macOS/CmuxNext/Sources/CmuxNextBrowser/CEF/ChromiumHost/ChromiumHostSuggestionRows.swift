import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextInput

/// A page's suggestion rows (``ChromiumHostSuggestionPopup``), each a shared ``PopupRowView``: an
/// entry's main and minor text with its label lines under it, a title, a footer after a hairline,
/// and Chrome's delete button on an autocomplete entry (`PopupRowView`'s, chrome/browser/ui/views/
/// autofill/popup/popup_row_view.cc). Chromium owns the one highlight (the keys move it; the pointer
/// reports through `onHover`). The list is VoiceOver's: Chromium's field has no list of its own.
final class ChromiumHostSuggestionRows: NSView {
    private let onHover: (Int?) -> Void
    private let onPick: (Int) -> Void
    private let onRemove: (Int) -> Void
    private var shownRows: [ChromiumHostSuggestions.Row] = []
    /// One view per row, in row order (a separator's is a hairline).
    private(set) var rowViews: [NSView] = []
    private(set) var highlighted: Int?
    private let style = PopupStyle.standard

    static let separatorHeight: CGFloat = 9
    static let titleHeight: CGFloat = 24
    /// An entry with label lines: the main text and one caption line.
    static let labeledHeight: CGFloat = 40

    /// Every row's moves, enters and exits on the list's one consumer: a delivery reports the row under
    /// the latest point. The pointer leaving the list lands the pending one (``mouseExited(with:)``).
    private(set) lazy var hoverMoves = PointerFrameHover(owner: "ChromiumHostSuggestionRows.hover", view: self) { [weak self] point in
        guard let self else { return }
        rowView(atWindowPoint: point)?.pointerMoved()
    }

    init(onHover: @escaping (Int?) -> Void, onPick: @escaping (Int) -> Void, onRemove: @escaping (Int) -> Void) {
        self.onHover = onHover
        self.onPick = onPick
        self.onRemove = onRemove
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Strings.suggestionsList)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeForHover, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {}

    /// The pointer left the list: the pending move lands, then no row is under it (Chrome clears its
    /// selection when the mouse leaves its rows, and the field shows its own value again).
    override func mouseExited(with event: NSEvent) {
        hoverMoves.flush()
        onHover(nil)
    }

    var contentHeight: CGFloat {
        2 * style.padding + shownRows.reduce(0) { $0 + Self.height(of: $1) }
    }

    static func height(of row: ChromiumHostSuggestions.Row) -> CGFloat {
        switch row.kind {
        case .separator: separatorHeight
        case .title: titleHeight
        case .entry, .footer: row.labels.isEmpty ? PopupStyle.standard.rowHeight : labeledHeight
        }
    }

    /// New rows (a new token): rebuilt, since Chromium's indices change with them; the same rows only
    /// move the highlight.
    func update(_ rows: [ChromiumHostSuggestions.Row], highlighted: Int?) {
        if rows != shownRows || rowViews.isEmpty != rows.isEmpty { rebuild(rows) }
        let size = NSSize(width: superview?.bounds.width ?? frame.width, height: contentHeight)
        if size != frame.size {
            setFrameSize(size)
            needsLayout = true // invalidate: the rows' frames follow the new size.
        }
        highlight(highlighted)
    }

    /// The one highlight: only the rows it left and reached redraw.
    func highlight(_ row: Int?) {
        highlighted = row
        for (index, view) in rowViews.enumerated() {
            guard let rowView = view as? PopupRowView else { continue }
            rowView.isHighlighted = index == row
            rowView.setAccessibilitySelected(index == row)
        }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if let row, rowViews.indices.contains(row) { scrollToVisible(frame(ofRow: row)) }
    }

    private func rebuild(_ rows: [ChromiumHostSuggestions.Row]) {
        shownRows = rows
        rowViews.forEach { $0.removeFromSuperview() }
        var layout = PopupRowView.Layout()
        layout.leadingColumn = 0
        layout.hoverFills = false
        rowViews = rows.enumerated().map { index, row in
            guard row.kind != .separator else { return ChromiumHostSuggestionSeparator() }
            let title = [row.main, row.minor].filter { !$0.isEmpty }.joined(separator: " ")
            let subtitle = row.labels.filter { !$0.isEmpty }.joined(separator: " · ")
            let view = PopupRowView(leading: nil, title: title, subtitle: subtitle, trailing: row.removable ? removeButton(row: index) : nil,
                                    layout: layout, interactive: row.kind != .title)
            if row.kind == .title { view.titleLabel.font = Typography.header }
            view.isEnabled = row.selectable && !row.loading
            view.setAccessibilityLabel(row.accessibilityLabel)
            view.onHover = { [weak self] in self?.onHover(index) }
            view.onActivate = { [weak self] in self?.onPick(index) }
            view.hoverMoves = hoverMoves
            return view
        }
        for view in rowViews {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        setAccessibilityChildren(rowViews.filter { !($0 is ChromiumHostSuggestionSeparator) })
    }

    private func removeButton(row: Int) -> NSView {
        let button = NSButton(image: NSImage.icon(.browserToolbarClose, size: 10), target: self, action: #selector(removePressed(_:)))
        button.isBordered = false
        button.tag = row
        button.toolTip = Strings.suggestionRemove
        button.setAccessibilityLabel(Strings.suggestionRemove)
        return button
    }

    @objc private func removePressed(_ sender: NSButton) {
        onRemove(sender.tag)
    }

    /// The row view under `windowPoint` now (a scroll since the move hit-tests the rows there).
    private func rowView(atWindowPoint windowPoint: CGPoint) -> PopupRowView? {
        let point = convert(windowPoint, from: nil)
        return rowViews.lazy.compactMap { $0 as? PopupRowView }.first { $0.frame.contains(point) }
    }

    private func frame(ofRow row: Int) -> CGRect {
        var y = style.padding
        for previous in shownRows.prefix(row) { y += Self.height(of: previous) }
        return CGRect(x: style.padding, y: y, width: max(0, bounds.width - 2 * style.padding), height: Self.height(of: shownRows[row]))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width]
    }

    override func layout() {
        super.layout()
        for index in rowViews.indices { rowViews[index].frame = frame(ofRow: index) }
    }
}

/// A hairline between groups of rows (Chrome's footer separator).
private final class ChromiumHostSuggestionSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.separator.setFill()
            NSRect(x: 6, y: bounds.midY.rounded(.down), width: max(0, bounds.width - 12), height: 1).fill()
        }
    }
}
