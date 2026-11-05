import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// `sidebar.topLeftCluster = listRow`: the + as a full-width "New Workspace" row at the top of the list. It sits
/// on the list rows' grid (the + on the leading-icon column, the label on the title column, the rows' fill inset
/// and corner radius), so the corner's first shape is a row like the ones under it rather than a lone glyph in
/// the titlebar. A press runs ``onPress``; its right-click menu is the +'s (``menuProvider``).
final class SidebarNewWorkspaceRow: ClickableButton {
    private(set) lazy var hover = ChromeHover(self, cornerRadius: SidebarStyle.rowCornerRadius, behindContent: true)
    var onPress: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onMenuOpenChange: ((Bool) -> Void)?
    let glyph = DecorativeImageView()
    let name = SidebarRowView.label(font: SidebarStyle.titleFont)
    private var renderedSide: CGFloat = 0

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .noImage
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        focusRingType = .none
        setAccessibilityLabel(Strings.newWorkspace)
        setAccessibilityIdentifier("cmux.sidebar.newWorkspaceRow")
        name.setString(Strings.newWorkspace)
        addSubview(glyph)
        addSubview(name)
        hover.followPointer(onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, let onPress else { return false }
        onPress()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        onMenuOpenChange?(true)
    }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        onMenuOpenChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        needsDisplay = true
        super.mouseDown(with: event)
        hover.state.pressed = false
        needsDisplay = true
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        let columns = SidebarStyle.columns(rowWidth: b.width)
        // The + glyph at Search's size, centered in the rows' leading icon box (where a workspace's favicon sits).
        let side = CGFloat.iconRowSize(forLabelPointSize: Metrics.iconSize)
        if side != renderedSide {
            renderedSide = side
            glyph.image = NSImage.icon(.actionAdd, size: side)
        }
        let box = columns.iconBox
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        glyph.frame = NSRect(x: snap(columns.lead + (box - side) / 2), y: snap(b.midY - side / 2), width: side, height: side)
        // The + is a leading mark: the label starts on the text column after the icon box, as Home's does.
        let x = columns.text(hasLeadingMark: true) - SidebarStyle.labelCellPadding
        name.setFont(SidebarStyle.titleFont)
        name.frame = NSRect(x: x, y: SidebarStyle.textY(name, centerY: b.midY), width: max(0, columns.textEnd(trailingMarks: 0) - x),
                            height: ceil(name.intrinsicContentSize.height))
    }

    override func updateLayer() {
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        layer?.cornerCurve = .continuous
        performWithTheme {
            let ink = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
            glyph.contentTintColor = ink
            name.setColor(ink)
        }
        hover.refresh(animated: false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover.state.pressed = false
        hover.pointer?.refresh()
    }
}
