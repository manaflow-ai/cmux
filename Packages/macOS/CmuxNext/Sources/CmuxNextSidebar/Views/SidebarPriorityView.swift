import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A compact, live projection of the workspace sidebar ordered by attention.
///
/// This deliberately keeps workspace identity at the model layer: selecting a
/// row sends the same `.select` intent as the regular sidebar list. The view is
/// a route over the existing `SidebarModel.priorityItems`, not a second store.
final class SidebarPriorityView: NSView {
    private let model: SidebarModel
    private let header = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private var rows: [SidebarPriorityRowView] = []
    private var focusedIndex = 0
    var onSelect: ((WorkspaceID) -> Void)?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        header.font = SidebarStyle.headerFont
        header.lineBreakMode = .byTruncatingTail
        header.setAccessibilityLabel(Strings.priorityView)
        empty.font = SidebarStyle.subtitleFont
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 2
        empty.stringValue = Strings.priorityEmpty
        addSubview(header)
        addSubview(empty)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Strings.priorityView)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !rows.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126: // up
            focusedIndex = max(0, focusedIndex - 1)
            updateKeyboardFocus()
        case 125: // down
            focusedIndex = min(rows.count - 1, focusedIndex + 1)
            updateKeyboardFocus()
        case 36, 49: // return or space
            guard model.priorityItems.indices.contains(focusedIndex) else {
                reload()
                return
            }
            onSelect?(model.priorityItems[focusedIndex].id)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateKeyboardFocus() {
        for (index, row) in rows.enumerated() {
            row.isKeyboardFocused = index == focusedIndex
        }
    }

    /// Rebuilds the small projection after an attention or workspace change.
    func reload() {
        let items = model.priorityItems
        for row in rows { row.removeFromSuperview() }
        focusedIndex = min(focusedIndex, max(0, items.count - 1))
        rows = items.enumerated().map { index, item in
            let row = SidebarPriorityRowView(item: item)
            row.onPress = { [weak self] id in
                guard let self else { return }
                focusedIndex = index
                updateKeyboardFocus()
                window?.makeFirstResponder(self)
                onSelect?(id)
            }
            addSubview(row)
            return row
        }
        updateKeyboardFocus()
        header.stringValue = Strings.priorityView
        empty.isHidden = !items.isEmpty
        needsLayout = true
    }

    /// Keeps the document view at the clip width while allowing it to scroll.
    func fitToWidth(_ width: CGFloat) {
        frame.size = NSSize(width: width, height: fittingHeight(width: width))
        needsLayout = true
    }

    private func fittingHeight(width: CGFloat) -> CGFloat {
        let rowHeight = SidebarPriorityRowView.height
        return Metrics.space3 + SidebarStyle.headerFont.pointSize + Metrics.space2
            + (rows.isEmpty ? SidebarStyle.subtitleFont.pointSize * 2 + Metrics.space2 : CGFloat(rows.count) * rowHeight)
            + Metrics.space3
    }

    override func layout() {
        super.layout()
        let inset = Metrics.space3
        let headerHeight = ceil(header.intrinsicContentSize.height)
        header.frame = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: headerHeight)
        if rows.isEmpty {
            let y = header.frame.maxY + Metrics.space2
            empty.frame = NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: ceil(empty.intrinsicContentSize.height))
        } else {
            empty.frame = .zero
            var y = header.frame.maxY + Metrics.space2
            for row in rows {
                row.frame = NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: SidebarPriorityRowView.height)
                y += SidebarPriorityRowView.height
            }
        }
    }
}

private final class SidebarPriorityRowView: NSView {
    static let height: CGFloat = 46
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let item: SidebarPriorityItem
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true } } }
    var onPress: ((WorkspaceID) -> Void)?

    init(item: SidebarPriorityItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        glyph.image = NSImage.icon(item.workspace.kind.iconName, size: .iconRowSize(forLabelPointSize: SidebarStyle.titleFont.pointSize))
        glyph.imageScaling = .scaleProportionallyDown
        title.font = SidebarStyle.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.stringValue = item.workspace.title
        detail.font = SidebarStyle.subtitleFont
        detail.lineBreakMode = .byTruncatingTail
        detail.stringValue = Self.bucketTitle(item.bucket)
        addSubview(glyph)
        addSubview(title)
        addSubview(detail)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.workspace.title), \(detail.stringValue)")
        setAccessibilityIdentifier("sidebar.priority.\(item.id.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress?(item.id) }

    override func accessibilityPerformPress() -> Bool {
        onPress?(item.id)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        performWithTheme {
            (isKeyboardFocused ? Palette.selectionFill : (hovering ? Palette.hoverFill : NSColor.clear)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: SidebarStyle.rowCornerRadius, yRadius: SidebarStyle.rowCornerRadius).fill()
            title.textColor = Palette.textPrimary
            detail.textColor = Palette.textTertiary
        }
    }

    override func layout() {
        super.layout()
        let x = Metrics.space2
        let side = CGFloat.iconRowSize(forLabelPointSize: SidebarStyle.titleFont.pointSize)
        glyph.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
        let textX = glyph.frame.maxX + Metrics.space2
        let textWidth = max(0, bounds.width - textX - Metrics.space2)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let detailHeight = ceil(detail.intrinsicContentSize.height)
        let total = titleHeight + detailHeight + Metrics.space1
        title.frame = NSRect(x: textX, y: (bounds.height - total) / 2, width: textWidth, height: titleHeight)
        detail.frame = NSRect(x: textX, y: title.frame.maxY + Metrics.space1, width: textWidth, height: detailHeight)
    }

    private static func bucketTitle(_ bucket: SidebarPriorityBucket) -> String {
        switch bucket {
        case .needsInput: Strings.activityNeedsInput
        case .failed: Strings.activityError
        case .working: Strings.activityRunning
        case .finished: Strings.activityDone
        case .idle: Strings.priorityIdle
        }
    }
}
