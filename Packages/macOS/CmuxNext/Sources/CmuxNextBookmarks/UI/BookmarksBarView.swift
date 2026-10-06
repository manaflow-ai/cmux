public import AppKit
import CmuxNextDesign

/// The bookmarks bar under a browser pane's toolbar (bookmarks.md section 3):
/// the Bookmarks Bar's children left to right, folders as menus, an overflow
/// chevron for what does not fit, and Other Bookmarks at the trailing end
/// when it has anything. Drag an item to reorder it; drop a link to bookmark
/// it there. Frames are laid out by hand (no Auto Layout inside the bar).
public final class BookmarksBarView: NSView {
    public static var height: CGFloat { Metrics.tabHeight + Metrics.space2 }
    static let dragType = NSPasteboard.PasteboardType("com.cmuxterm.bookmark-id")

    public weak var source: (any BookmarksBarSource)? { didSet { reload() } }
    private var items: [BookmarkBarItemView] = []
    private var visibleCount = 0
    private let overflow = NSButton()
    private let otherButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let dropIndicator = CALayer()
    private var menus: [BookmarkFolderMenu] = []
    private var isStale = true

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isStale { reload() }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for button in [overflow, otherButton] {
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.target = self
            button.imagePosition = .imageLeading
            button.title = ""
            addSubview(button)
        }
        overflow.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: BookmarkStrings.moreBookmarks)
        overflow.toolTip = BookmarkStrings.moreBookmarks
        overflow.action = #selector(showOverflow)
        otherButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        otherButton.title = BookmarkStrings.otherBookmarks
        otherButton.action = #selector(showOther)
        emptyLabel.stringValue = BookmarkStrings.barEmptyHint
        emptyLabel.lineBreakMode = .byTruncatingTail
        addSubview(emptyLabel)
        dropIndicator.isHidden = true
        layer?.addSublayer(dropIndicator)
        registerForDraggedTypes([Self.dragType, .URL])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(BookmarkStrings.barTitle)
        setAccessibilityIdentifier("cmux.bookmarks.bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Rebuilds the items from the source (the host calls it when the
    /// profile's bookmarks change). A bar not in a window (a hidden tab)
    /// rebuilds when it is shown again.
    public func reload() {
        guard window != nil else {
            isStale = true
            return
        }
        isStale = false
        items.forEach { $0.removeFromSuperview() }
        items = (source?.bookmarkChildren(of: BookmarkRoot.bar.rawValue) ?? []).map { node in
            let item = BookmarkBarItemView(node: node, image: source?.favicon(for: node))
            item.onClick = { [weak self] item, event in self?.click(item, event) }
            item.onDragStart = { [weak self] item, event in self?.beginDrag(item, event) }
            item.onContextMenu = { [weak self] item in self?.source?.contextMenu(for: item.node) }
            addSubview(item)
            return item
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Item titles in bar order, visible first (diagnostics, `debug.bookmarks`).
    public var visibleTitles: [String] { items.prefix(visibleCount).map(\.node.displayTitle) }
    public var overflowTitles: [String] { items.dropFirst(visibleCount).map(\.node.displayTitle) }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let inset = Metrics.paneChromeInset
        let itemHeight = Metrics.tabHeight
        let y = (bounds.height - itemHeight) / 2
        otherButton.font = Typography.body
        overflow.font = Typography.body
        let hasOther = !(source?.bookmarkChildren(of: BookmarkRoot.other.rawValue).isEmpty ?? true)
        otherButton.isHidden = !hasOther
        let otherWidth = hasOther ? ceil(otherButton.intrinsicContentSize.width) + Metrics.space4 : 0
        let chevronWidth = itemHeight
        var limit = bounds.width - inset - otherWidth
        var x = inset
        visibleCount = 0
        let total = items.reduce(inset) { $0 + $1.preferredWidth + Metrics.space1 }
        if total > limit { limit -= chevronWidth }
        var fits = true
        for item in items {
            let width = item.preferredWidth
            fits = fits && x + width <= limit
            item.isHidden = !fits
            guard fits else { continue }
            item.frame = NSRect(x: x, y: y, width: width, height: itemHeight)
            x += width + Metrics.space1
            visibleCount += 1
        }
        overflow.isHidden = visibleCount == items.count
        overflow.frame = NSRect(x: x, y: y, width: chevronWidth, height: itemHeight)
        otherButton.frame = NSRect(x: bounds.width - inset - otherWidth, y: y, width: otherWidth, height: itemHeight)
        emptyLabel.font = Typography.caption
        emptyLabel.isHidden = !items.isEmpty
        let labelHeight = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = NSRect(x: inset + Metrics.space4, y: (bounds.height - labelHeight) / 2,
                                  width: max(0, bounds.width - 2 * inset - otherWidth - Metrics.space4), height: labelHeight)
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.paneFill.cgColor
            emptyLabel.textColor = Palette.textTertiary
            otherButton.contentTintColor = Palette.textSecondary
            overflow.contentTintColor = Palette.textSecondary
            dropIndicator.backgroundColor = Palette.textSecondary.cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Clicks and menus

    private func click(_ item: BookmarkBarItemView, _ event: NSEvent) {
        guard let source else { return }
        if item.node.isFolder {
            let menu = BookmarkFolderMenu(source: source, folder: item.node.id, title: item.node.displayTitle)
            popUp(menu, below: item)
        } else {
            source.open(item.node, disposition: .from(event.modifierFlags, middleButton: event.type == .otherMouseUp))
        }
    }

    @objc private func showOverflow() {
        guard let source else { return }
        let hidden = items.dropFirst(visibleCount).map(\.node)
        popUp(BookmarkFolderMenu(source: source, folder: "", title: BookmarkStrings.moreBookmarks, leading: hidden, includeChildren: false),
              below: overflow)
    }

    @objc private func showOther() {
        guard let source else { return }
        popUp(BookmarkFolderMenu(source: source, folder: BookmarkRoot.other.rawValue, title: BookmarkStrings.otherBookmarks),
              below: otherButton)
    }

    private func popUp(_ folderMenu: BookmarkFolderMenu, below view: NSView) {
        menus = [folderMenu]
        folderMenu.menuNeedsUpdate(folderMenu.menu)
        folderMenu.menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: view, gap: 2), in: view)
    }

    public override func menu(for event: NSEvent) -> NSMenu? { source?.contextMenu(for: nil) }

    // MARK: Drag and drop (BookmarksBarView+Drag)

    var barItems: [BookmarkBarItemView] { items }
    var dropLayer: CALayer { dropIndicator }
}
