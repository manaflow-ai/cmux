import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The Extensions bubble's content, Chrome's legacy `ExtensionsMenuView`: the title
/// "Extensions" with a close button, one row per extension (scrolling above 448 points), a
/// separator, and Manage Extensions with Chrome's gear.
///
/// Rows are kept by extension id and reused: an open shows the rows it already has and changes
/// only the ones whose extension changed.
final class ExtensionsMenuView: NSView {
    /// Callbacks of the bubble's controls.
    struct Actions {
        var run: (String) -> Void = { _ in }
        var pin: (String, Bool) -> Void = { _, _ in }
        var more: (String, NSView) -> Void = { _, _ in }
        var manage: () -> Void = {}
        var close: () -> Void = {}
    }

    var actions = Actions()
    private let style: ExtensionsMenuStyle
    private let titleLabel = ThemedLabel(labelWithString: "")
    let closeButton: ExtensionsMenuHoverButton
    private let scrollView = NSScrollView()
    private let list = ExtensionsMenuListView()
    private let emptyLabel = ThemedLabel(labelWithString: "")
    private let separator = ExtensionsMenuSeparator()
    let manageButton: ExtensionsMenuHoverButton
    private(set) var rows: [ExtensionsMenuItemView] = []
    private var rowsByID: [String: ExtensionsMenuItemView] = [:]
    /// Extra rows: a note under the list (the built-in ad blocker).
    private var listHeight: CGFloat = 0

    /// The header: the title's top inset and the close button's row.
    private var headerHeight: CGFloat { 16 + style.closeButton + 8 }
    private var footerHeight: CGFloat { style.buttonMargin * 2 + style.buttonIcon }

    init(style: ExtensionsMenuStyle = .chrome) {
        self.style = style
        closeButton = ExtensionsMenuHoverButton(
            image: NSImage.icon(.browserToolbarClose, size: style.closeGlyph), imageSize: style.closeGlyph, imageBox: style.closeGlyph,
            insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), style: style
        )
        manageButton = ExtensionsMenuHoverButton(
            image: NSImage.icon(.browserExtensionsManage, size: style.buttonIcon), imageSize: style.buttonIcon,
            imageBox: style.buttonIcon, title: Strings.extensionMenuTitle(.manage),
            insets: NSEdgeInsets(top: style.buttonMargin, left: style.dialogInset + style.iconSpacing,
                                 bottom: style.buttonMargin, right: style.dialogInset),
            imageLabelSpacing: style.imageLabelSpacing + style.iconSpacing, style: style
        )
        super.init(frame: NSRect(x: 0, y: 0, width: style.width, height: 100))
        titleLabel.stringValue = Strings.extensions
        titleLabel.font = style.titleFont
        titleLabel.themeColor = { Palette.textPrimary }
        titleLabel.setAccessibilityRole(.staticText)
        closeButton.themedToolTip = Strings.extensionMenuClose
        closeButton.setAccessibilityLabel(Strings.extensionMenuClose)
        closeButton.setAccessibilityIdentifier("\(ExtensionsMenu.menuIdentifier).close")
        closeButton.onPress = { [weak self] in self?.actions.close() }
        manageButton.setAccessibilityIdentifier(ExtensionsMenu.footerIdentifier(.manage))
        manageButton.onPress = { [weak self] in self?.actions.manage() }
        emptyLabel.stringValue = Strings.noExtensions
        emptyLabel.font = style.labelFont
        emptyLabel.themeColor = { Palette.textSecondary }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = list
        for view in [titleLabel, closeButton, scrollView, emptyLabel, separator, manageButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `extensions` in order. A row for an extension shown before is reused and updated in
    /// place; rows of extensions no longer listed go.
    func update(_ extensions: [BrowserExtensionInfo], icon: (BrowserExtensionInfo) -> NSImage,
                canPin: (BrowserExtensionInfo) -> Bool, tooltip: (BrowserExtensionInfo) -> String?) {
        var next: [ExtensionsMenuItemView] = []
        var byID: [String: ExtensionsMenuItemView] = [:]
        for info in extensions {
            let image = icon(info)
            let row: ExtensionsMenuItemView
            if let existing = rowsByID[info.id] {
                if existing.info != info || existing.canPin != canPin(info) { existing.apply(info, icon: image, canPin: canPin(info)) }
                row = existing
            } else {
                row = makeRow(info, icon: image, canPin: canPin(info))
            }
            row.primary.themedToolTip = tooltip(info)
            next.append(row)
            byID[info.id] = row
        }
        for row in rows where byID[row.extensionID] == nil { row.removeFromSuperview() }
        for row in next where row.superview !== list { list.addSubview(row) }
        rows = next
        rowsByID = byID
        emptyLabel.isHidden = !extensions.isEmpty
        listHeight = extensions.isEmpty ? 32 : CGFloat(extensions.count) * style.rowHeight
        let height = headerHeight + min(listHeight, style.maxListHeight) + 1 + footerHeight
        setFrameSize(NSSize(width: style.width, height: height))
        needsLayout = true
    }

    private func makeRow(_ info: BrowserExtensionInfo, icon: NSImage, canPin: Bool) -> ExtensionsMenuItemView {
        let row = ExtensionsMenuItemView(info: info, icon: icon, canPin: canPin, style: style)
        let id = info.id
        row.onRun = { [weak self] in self?.actions.run(id) }
        row.onPin = { [weak self] pinned in self?.actions.pin(id, pinned) }
        row.onMore = { [weak self, weak row] in
            guard let self, let row else { return }
            actions.more(id, row.moreButton)
        }
        return row
    }

    /// The row of extension `id`, when listed.
    func row(for id: String) -> ExtensionsMenuItemView? { rowsByID[id] }

    /// The keyboard order: the rows' buttons, Manage Extensions, then the close button (Chrome's
    /// arrow keys walk the bubble's focus chain).
    var focusOrder: [NSView] { rows.flatMap(\.focusableButtons) + [manageButton, closeButton] }

    override func layout() {
        super.layout()
        let inset = style.dialogInset
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        closeButton.frame = NSRect(x: bounds.width - 16 - style.closeButton, y: 16, width: style.closeButton, height: style.closeButton)
        titleLabel.frame = NSRect(x: inset, y: 16 + (style.closeButton - titleHeight) / 2,
                                  width: max(0, closeButton.frame.minX - inset - 8), height: titleHeight)
        let visible = min(listHeight, style.maxListHeight)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: visible)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: listHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: CGFloat(index) * style.rowHeight, width: bounds.width - inset * 2, height: style.rowHeight)
        }
        let emptyHeight = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = NSRect(x: inset, y: headerHeight + (32 - emptyHeight) / 2, width: bounds.width - inset * 2, height: emptyHeight)
        separator.frame = NSRect(x: 0, y: headerHeight + visible, width: bounds.width, height: 1)
        manageButton.frame = NSRect(x: 0, y: separator.frame.maxY, width: bounds.width, height: footerHeight)
    }

    /// Scrolls the list so `view` (a row's button) shows: the keyboard moved onto it.
    func reveal(_ view: NSView) {
        guard view.isDescendant(of: list) else { return }
        list.scrollToVisible(view.convert(view.bounds, to: list))
    }
}

/// A flipped plain view: the list grows downward from its top.
private final class ExtensionsMenuListView: NSView {
    override var isFlipped: Bool { true }
}

/// A one-point line in the theme's separator color (Chrome's `views::Separator`).
private final class ExtensionsMenuSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.separator.setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
