#if os(macOS)
import AppKit
import CmuxConversationCore

/// A conversation list action. The context menu, the trackpad swipe buttons,
/// pin drag and drop and the lab hooks all go through
/// `MacConversationListViewController.perform(_:on:)`.
public enum MacConversationListAction: String, Sendable, CaseIterable {
    case togglePin
    case toggleUnread
    case toggleAlerts
    /// Asks "Are you sure you want to delete this conversation?" first.
    case delete
}

/// Messages' list strings (ChatKit keys in comments).
enum MacListStrings {
    // PIN / REMOVE_PIN_ACTION
    static var pin: String { String(localized: "conversation.list.pin", defaultValue: "Pin", bundle: .module) }
    static var unpin: String { String(localized: "conversation.list.unpin", defaultValue: "Unpin", bundle: .module) }
    // MARK_AS_UNREAD / MARK_AS_READ
    static var markUnread: String { String(localized: "conversation.list.markUnread", defaultValue: "Mark as Unread", bundle: .module) }
    static var markRead: String { String(localized: "conversation.list.markRead", defaultValue: "Mark as Read", bundle: .module) }
    // MARK_AS_UNREAD_BUTTON / MARK_AS_READ_BUTTON (swipe buttons)
    static var unreadButton: String { String(localized: "conversation.list.unreadButton", defaultValue: "Unread", bundle: .module) }
    static var readButton: String { String(localized: "conversation.list.readButton", defaultValue: "Read", bundle: .module) }
    // CONVERSATION_LIST_CONTEXT_MENU_HIDE_ALERTS_ACTION_TITLE / _SHOW_ALERTS_
    static var hideAlerts: String { String(localized: "conversation.list.hideAlerts", defaultValue: "Hide Alerts", bundle: .module) }
    static var showAlerts: String { String(localized: "conversation.list.showAlerts", defaultValue: "Show Alerts", bundle: .module) }
    // DELETE_CONVERSATION_ELLIPSIS / DELETE
    static var deleteConversation: String { String(localized: "conversation.list.deleteConversation", defaultValue: "Delete Conversation…", bundle: .module) }
    static var delete: String { String(localized: "conversation.list.delete", defaultValue: "Delete", bundle: .module) }
    static var cancel: String { String(localized: "conversation.list.cancel", defaultValue: "Cancel", bundle: .module) }
    // DELETE_ALERT_MESSAGE / DELETE_ALERT_MESSAGE_ON_ICLOUD
    static var deleteAlertTitle: String {
        String(localized: "conversation.list.deleteAlert.title", defaultValue: "Are you sure you want to delete this conversation?", bundle: .module)
    }
    static var deleteAlertMessage: String {
        String(localized: "conversation.list.deleteAlert.message", defaultValue: "This conversation will be deleted from all of your devices.", bundle: .module)
    }
    // CANNOT_PIN_MORE_CONVERSATIONS_ALERT_TITLE / _MESSAGE
    static var pinLimitTitle: String { String(localized: "conversation.list.pinLimit.title", defaultValue: "Pinned Conversations", bundle: .module) }
    static var pinLimitMessage: String {
        String(localized: "conversation.list.pinLimit.message", defaultValue: "You can pin up to 9 conversations. To pin this conversation, unpin another one first.", bundle: .module)
    }
    static var ok: String { String(localized: "conversation.list.ok", defaultValue: "OK", bundle: .module) }
    // PIN_CONVERSATION_DROP_TARGET_LABEL
    static var dropToPin: String { String(localized: "conversation.list.dropToPin", defaultValue: "Drag here to pin", bundle: .module) }
    static var alertsHidden: String { String(localized: "conversation.list.alertsHidden", defaultValue: "Alerts hidden", bundle: .module) }
}

extension NSPasteboard.PasteboardType {
    /// A conversation id dragged within the sidebar (to pin, unpin or reorder).
    static let cmuxConversationID = NSPasteboard.PasteboardType("com.cmux.conversation.id")
}

/// Pinned conversations: large avatars, three to a row, at the top of the
/// sidebar. Tiles drag to reorder, to unpin (dropped on the list) and accept
/// list rows dropped on them to pin.
@MainActor
final class MacPinnedGridView: MacFlippedView {
    struct Tile {
        var id: String
        var store: ConversationStore
        var isUnread: Bool
    }

    static let columns = 3
    /// Low confidence (macOS capture is blocked on the fleet): sized from
    /// Messages' 3-column pins at the 328 pt default sidebar width.
    static let avatarSize: CGFloat = 64
    static let tileHeight: CGFloat = 100
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 8
    static let placeholderHeight: CGFloat = 64

    private(set) var tiles: [Tile] = []
    private var tileViews: [MacPinnedTileView] = []
    private let placeholder = makeMacLabel()
    var selectedID: String? { didSet { tileViews.forEach { $0.isSelected = $0.id == selectedID && $0.id != nil } } }
    /// Shows the "Drag here to pin" target while a row is dragged.
    var showsDropTarget = false { didSet { needsLayout = true; needsDisplay = true } }
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    var onSelect: ((String) -> Void)?
    var menuProvider: ((String) -> NSMenu?)?
    /// `(id, index)`: pin `id` (or move it) to `index` among the pins.
    var onDropAt: ((String, Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholder.stringValue = MacListStrings.dropToPin
        placeholder.font = .systemFont(ofSize: 12, weight: .medium)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        addSubview(placeholder)
        registerForDraggedTypes([.cmuxConversationID])
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("conversation.sidebar.pins")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func height(count: Int, showsDropTarget: Bool) -> CGFloat {
        guard count > 0 else { return showsDropTarget ? placeholderHeight : 0 }
        let rows = (count + columns - 1) / columns
        return topInset + CGFloat(rows) * tileHeight + bottomInset
    }

    func configure(_ tiles: [Tile]) {
        self.tiles = tiles
        while tileViews.count < tiles.count {
            let view = MacPinnedTileView()
            view.onSelect = { [weak self] id in self?.onSelect?(id) }
            view.menuProvider = { [weak self] id in self?.menuProvider?(id) }
            addSubview(view)
            tileViews.append(view)
        }
        while tileViews.count > tiles.count { tileViews.removeLast().removeFromSuperview() }
        for (view, tile) in zip(tileViews, tiles) {
            view.configure(tile)
            view.isSelected = tile.id == selectedID
        }
        needsLayout = true
    }

    private func tileFrame(_ index: Int) -> CGRect {
        let columns = Self.columns
        let width = (bounds.width - 20) / CGFloat(columns)
        let row = index / columns
        let inRow = min(columns, tiles.count - row * columns)
        // A short last row is centered, as Messages centers one or two pins.
        let lead = 10 + (bounds.width - 20 - width * CGFloat(inRow)) / 2
        return CGRect(x: lead + CGFloat(index % columns) * width, y: Self.topInset + CGFloat(row) * Self.tileHeight, width: width, height: Self.tileHeight)
    }

    override func layout() {
        super.layout()
        for (index, view) in tileViews.enumerated() {
            view.frame = tileFrame(index)
            // A tile measures its name against its own width.
            view.needsLayout = true
        }
        placeholder.isHidden = !(tiles.isEmpty && showsDropTarget)
        placeholder.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: bounds.width - 20, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsDropTarget || dropHighlighted else { return }
        let area = bounds.insetBy(dx: 12, dy: 6)
        let path = NSBezierPath(roundedRect: area, xRadius: 12, yRadius: 12)
        if dropHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
        }
        if tiles.isEmpty {
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            (dropHighlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            path.stroke()
        }
    }

    /// Insertion index among the pins for a drop at `point`.
    func insertionIndex(at point: CGPoint) -> Int {
        guard !tiles.isEmpty else { return 0 }
        // The nearest tile; dropping on its leading half goes before it.
        let nearest = tiles.indices.min { lhs, rhs in
            let a = tileFrame(lhs), b = tileFrame(rhs)
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        } ?? 0
        return point.x < tileFrame(nearest).midX ? nearest : nearest + 1
    }

    // MARK: Drop target

    private func draggedID(_ info: any NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .cmuxConversationID)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard draggedID(sender) != nil else { return [] }
        dropHighlighted = true
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHighlighted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard let id = draggedID(sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onDropAt?(id, insertionIndex(at: point))
        return true
    }
}

/// One pinned conversation: a large avatar with the name under it.
@MainActor
final class MacPinnedTileView: MacFlippedView, NSDraggingSource {
    private(set) var id: String?
    private let avatar = MacAvatarView()
    private let clusterDisc = MacFlippedView()
    private var cluster: [MacAvatarView] = []
    private let name = makeMacLabel()
    private let unreadDot = MacFlippedView()
    private let mutedGlyph = NSImageView()
    private let highlight = MacFlippedView()
    private var mouseDownEvent: NSEvent?
    var onSelect: ((String) -> Void)?
    var menuProvider: ((String) -> NSMenu?)?
    var isSelected = false { didSet { updateHighlight() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 12
        addSubview(highlight)
        clusterDisc.wantsLayer = true
        addSubview(clusterDisc)
        addSubview(avatar)
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.alignment = .center
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 6
        unreadDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        unreadDot.layer?.borderWidth = 2
        addSubview(unreadDot)
        mutedGlyph.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: MacListStrings.alertsHidden)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        mutedGlyph.contentTintColor = .secondaryLabelColor
        addSubview(mutedGlyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tile: MacPinnedGridView.Tile) {
        id = tile.id
        let store = tile.store
        let info = store.info
        let others = info?.participants.filter { $0.id != store.meID } ?? []
        cluster.forEach { $0.removeFromSuperview() }
        cluster = []
        let isGroup = info?.kind == .group
        avatar.isHidden = isGroup
        clusterDisc.isHidden = !isGroup
        if isGroup {
            cluster = others.prefix(3).map { participant in
                let view = MacAvatarView()
                view.initials = participant.initials
                view.colorHex = participant.colorHex
                addSubview(view)
                return view
            }
        } else {
            avatar.initials = others.first?.initials ?? ""
            avatar.colorHex = others.first?.colorHex
        }
        // Messages labels a pinned person by first name, a group by its name.
        let person = isGroup ? nil : others.first?.name.split(separator: " ").first.map(String.init)
        name.stringValue = person ?? info?.title ?? ""
        unreadDot.isHidden = !tile.isUnread
        mutedGlyph.isHidden = !store.listState.muted
        setAccessibilityIdentifier("conversation.sidebar.pin.\(tile.id)")
        setAccessibilityLabel(info?.title ?? tile.id)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = MacPinnedGridView.avatarSize
        let disc = CGRect(x: (bounds.width - size) / 2, y: 8, width: size, height: size)
        highlight.frame = bounds.insetBy(dx: 2, dy: 0)
        avatar.frame = disc
        clusterDisc.frame = disc
        clusterDisc.layer?.cornerRadius = size / 2
        clusterDisc.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.45).cgColor
        // The row cluster scaled from its 40 pt disc to the pin's.
        let scale = size / 40
        let frames = [
            CGRect(x: disc.midX + (-6 - 9) * scale, y: disc.midY + (-6 - 9) * scale, width: 18 * scale, height: 18 * scale),
            CGRect(x: disc.midX + (9.5 - 7) * scale, y: disc.midY + (4 - 7) * scale, width: 14 * scale, height: 14 * scale),
            CGRect(x: disc.midX + (-3 - 5.5) * scale, y: disc.midY + (11 - 5.5) * scale, width: 11 * scale, height: 11 * scale),
        ]
        for (index, view) in cluster.enumerated() where index < frames.count { view.frame = frames[index] }
        // The cell's own width (text plus the field's padding), capped to the tile.
        let nameWidth = min(bounds.width - 8, ceil(name.cell?.cellSize.width ?? name.intrinsicContentSize.width))
        let glyphWidth: CGFloat = mutedGlyph.isHidden ? 0 : 13
        let nameX = (bounds.width - nameWidth - glyphWidth) / 2 + glyphWidth
        name.frame = CGRect(x: nameX, y: disc.maxY + 7, width: nameWidth, height: 15)
        mutedGlyph.frame = CGRect(x: nameX - glyphWidth, y: disc.maxY + 8, width: 11, height: 13)
        unreadDot.frame = CGRect(x: disc.minX + 1, y: disc.minY + 1, width: 12, height: 12)
        unreadDot.layer?.borderColor = resolved(NSColor.windowBackgroundColor, in: self)
        updateHighlight()
    }

    private func updateHighlight() {
        let active = isSelected && window?.isKeyWindow == true
        highlight.isHidden = !isSelected
        highlight.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.cgColor
            : resolved(effectiveAppearance.isDarkMac ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06), in: self)
        name.textColor = active ? .white : .labelColor
        mutedGlyph.contentTintColor = active ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, let id, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let id else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        mouseDownEvent = nil
        let item = NSPasteboardItem()
        item.setString(id, forType: .cmuxConversationID)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: avatar.frame.size)
        if let rep = bitmapImageRepForCachingDisplay(in: avatar.frame) {
            cacheDisplay(in: avatar.frame, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(avatar.frame, contents: image)
        beginDraggingSession(with: [dragItem], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        id.flatMap { menuProvider?($0) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let id else { return false }
        onSelect?(id)
        return true
    }
}
#endif
