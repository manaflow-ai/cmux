import AppKit
import CmuxNextDesign
import QuartzCore

/// The rail look's column (plans/cmux-next/sidebar-sections.md 11): the
/// sidebar's sticky bands as icon buttons, laid out by
/// `SidebarRailLayout`. Each button is an icon-style item row, so press,
/// hover, the context menu and VoiceOver behave as in the sidebar; its
/// tooltip is the item's title and live shortcut, supplied by the App. It
/// paints no background: it sits on the window's backdrop like the
/// sidebar. Section lines go through `Palette.separator` and
/// `Metrics.lineWidth` (the metrics), so `appearance.borders = none`
/// removes them.
final class SidebarRailView: NSView {
    struct Content: Equatable {
        var document: SidebarLayoutDocument
        /// The room the window shows (room-scoped sections).
        var room: String?
        var infos: [LayoutItemID: SidebarItemInfo]
        /// "Settings (⌘,)": the App's title plus live shortcut; the title
        /// alone where an item has none.
        var toolTips: [LayoutItemID: String]
        var metrics: SidebarRailMetrics
    }

    var onActivate: ((LayoutItemID) -> Void)?
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    private(set) var layoutResult = SidebarRailLayout.empty
    private var content: Content?
    private var itemViews: [LayoutItemID: SidebarItemRowView] = [:]
    private var lineLayers: [CALayer] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The bottom band is pinned to the bottom edge, and a shorter rail
    /// overflows: every height change lays out again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.height != frame.height
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    func update(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        let result = SidebarRailLayout.make(document: content.document, room: content.room, height: bounds.height,
                                            metrics: content.metrics)
        layoutResult = result
        let shown = Set(result.buttons.map(\.item))
        for (id, view) in itemViews where !shown.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in result.buttons {
            let view = itemViews[button.item] ?? makeItem(button.item)
            let info = content.infos[button.item]
                ?? content.document.item(button.item).map { SidebarItemInfo.fallback(for: $0.ref) }
                ?? SidebarItemInfo(title: "", symbol: "circle", isMissing: true)
            view.configure(info, style: .icon)
            view.toolTip = content.toolTips[button.item] ?? info.title
            view.frame = button.frame
        }
        while lineLayers.count > result.separators.count { lineLayers.removeLast().removeFromSuperlayer() }
        while lineLayers.count < result.separators.count {
            let line = CALayer()
            layer?.addSublayer(line)
            lineLayers.append(line)
        }
        for (line, frame) in zip(lineLayers, result.separators) { line.frame = frame }
        CATransaction.commit()
        needsDisplay = true
    }

    private func makeItem(_ id: LayoutItemID) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.onPress = { [weak self] in self?.onActivate?(id) }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        addSubview(view)
        itemViews[id] = view
        return view
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            for line in lineLayers { line.backgroundColor = Palette.separator.cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(.background)
    }

    /// The item view for `id` (tests, hover cards).
    func itemView(_ id: LayoutItemID) -> SidebarItemRowView? { itemViews[id] }
}
