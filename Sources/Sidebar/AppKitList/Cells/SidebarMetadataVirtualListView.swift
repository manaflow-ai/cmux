import AppKit
import CmuxFoundation
import CmuxSidebar

/// Viewport-virtualized metadata lines for one pure-AppKit workspace row.
///
/// Unlimited metadata keeps the complete authoritative entry array, but only
/// entries intersecting the enclosing sidebar viewport own AppKit row views.
/// This prevents long-lived workspaces from accumulating one view hierarchy
/// per distinct metadata key.
@MainActor
final class SidebarMetadataVirtualListView: NSView {
    private static let rowSpacing: CGFloat = 2
    private static let detachedMaterializationLimit = 16

    private(set) var entries: [SidebarStatusEntry] = []
    private var model: SidebarWorkspaceRowModel?
    private var onOpenURL: ((URL) -> Void)?
    private(set) var rowsByEntryIndex: [Int: SidebarRowIconTextLine] = [:]
    private weak var observedClipView: NSClipView?

    private(set) var materializedEntryRange: Range<Int> = 0..<0

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: measuredHeight(width: bounds.width)
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(
        entries: [SidebarStatusEntry],
        model: SidebarWorkspaceRowModel,
        onOpenURL: @escaping (URL) -> Void
    ) {
        self.entries = entries
        self.model = model
        self.onOpenURL = onOpenURL
        isHidden = entries.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
        refreshClipObservation()
        updateMaterializedRows(reconfiguringExistingRows: true)
    }

    func measuredHeight(width _: CGFloat) -> CGFloat {
        guard let model, !entries.isEmpty else { return 0 }
        return CGFloat(entries.count) * Self.rowHeight(for: model)
            + CGFloat(entries.count - 1) * Self.rowSpacing
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshClipObservation()
        updateMaterializedRows()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshClipObservation()
        updateMaterializedRows()
    }

    override func layout() {
        super.layout()
        refreshClipObservation()
        updateMaterializedRows()
    }

    private static func rowHeight(for model: SidebarWorkspaceRowModel) -> CGFloat {
        let font = NSFont.systemFont(ofSize: model.scaled(10))
        let textHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let largestIconHeight = model.scaled(9) + 3
        return max(textHeight, largestIconHeight)
    }

    private func refreshClipObservation() {
        let clipView = entries.count > Self.detachedMaterializationLimit
            ? enclosingScrollView?.contentView
            : nil
        guard observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc
    private func clipBoundsDidChange(_ notification: Notification) {
        guard notification.object as? NSClipView === observedClipView else { return }
        updateMaterializedRows()
    }

    private func updateMaterializedRows(reconfiguringExistingRows: Bool = false) {
        guard let model, !entries.isEmpty else {
            removeAllMaterializedRows()
            return
        }

        let targetRange = targetEntryRange(model: model)
        guard reconfiguringExistingRows
                || targetRange != materializedEntryRange
                || rowsByEntryIndex.count != targetRange.count else {
            layoutMaterializedRows(model: model)
            return
        }

        var recycledRows: [SidebarRowIconTextLine] = []
        let recycledIndexes = rowsByEntryIndex.keys.filter { !targetRange.contains($0) }
        for index in recycledIndexes {
            guard let row = rowsByEntryIndex.removeValue(forKey: index) else { continue }
            recycledRows.append(row)
        }

        let palette = SidebarRowPalette(model: model)
        for index in targetRange {
            if let row = rowsByEntryIndex[index] {
                if reconfiguringExistingRows {
                    configure(
                        row: row,
                        entry: entries[index],
                        model: model,
                        palette: palette
                    )
                }
            } else {
                let row = recycledRows.popLast() ?? SidebarRowIconTextLine()
                if row.superview == nil {
                    addSubview(row)
                }
                configure(
                    row: row,
                    entry: entries[index],
                    model: model,
                    palette: palette
                )
                rowsByEntryIndex[index] = row
            }
        }
        recycledRows.forEach { $0.removeFromSuperview() }
        materializedEntryRange = targetRange
        layoutMaterializedRows(model: model)
    }

    private func targetEntryRange(model: SidebarWorkspaceRowModel) -> Range<Int> {
        guard observedClipView != nil else {
            return 0..<min(entries.count, Self.detachedMaterializationLimit)
        }
        let viewport = visibleRect.intersection(bounds)
        guard !viewport.isEmpty else { return 0..<0 }

        let rowHeight = Self.rowHeight(for: model)
        let stride = rowHeight + Self.rowSpacing
        let firstIntersecting = Int(floor((viewport.minY - rowHeight) / stride)) + 1
        let lastVisibleExclusive = Int(ceil(viewport.maxY / stride))
        let lowerBound = min(entries.count, max(0, firstIntersecting - 1))
        let upperBound = min(entries.count, lastVisibleExclusive + 1)
        return lowerBound..<max(lowerBound, upperBound)
    }

    private func configure(
        row: SidebarRowIconTextLine,
        entry: SidebarStatusEntry,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        let explicitColor = entry.color.flatMap { NSColor(hex: $0) }
        let entryColor: NSColor
        if model.isActive {
            entryColor = explicitColor != nil
                ? palette.selectedForeground(1.0)
                : palette.secondary(0.95).withAlphaComponent(0.84)
        } else {
            entryColor = explicitColor ?? .secondaryLabelColor
        }
        row.configureMetadataEntry(
            entry,
            model: model,
            color: entryColor
        ) { [weak self] url in
            self?.onOpenURL?(url)
        }
    }

    private func layoutMaterializedRows(model: SidebarWorkspaceRowModel) {
        let rowHeight = Self.rowHeight(for: model)
        let stride = rowHeight + Self.rowSpacing
        for (index, row) in rowsByEntryIndex {
            row.frame = NSRect(
                x: 0,
                y: CGFloat(index) * stride,
                width: bounds.width,
                height: rowHeight
            )
        }
    }

    private func removeAllMaterializedRows() {
        rowsByEntryIndex.values.forEach { $0.removeFromSuperview() }
        rowsByEntryIndex.removeAll(keepingCapacity: false)
        materializedEntryRange = 0..<0
    }
}
