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
        /// Keep the accessory slot (`accessoryView`).
        var accessory = false
    }

    var onActivate: ((LayoutItemID) -> Void)?
    var onActivateWithModifiers: ((LayoutItemID, NSEvent.ModifierFlags) -> Void)?
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    private(set) var layoutResult = SidebarRailLayout.empty
    private var content: Content?
    private var itemViews: [LayoutItemID: SidebarItemRowView] = [:]
    /// Lists the top-band items a short rail has no room for.
    private(set) var moreView: SidebarItemRowView?
    private var lineLayers: [CALayer] = []
    /// The App's accessory (the update circle), placed in the layout's
    /// accessory slot while `Content.accessory` holds.
    var accessoryView: NSView? {
        didSet {
            guard oldValue !== accessoryView else { return }
            oldValue?.removeFromSuperview()
            if let accessoryView { addSubview(accessoryView) }
            needsLayout = true
        }
    }

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
                                            metrics: content.metrics, accessory: content.accessory && accessoryView != nil)
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
        if let frame = result.more {
            let view = moreView ?? makeMore()
            view.configure(SidebarItemInfo(title: SectionStrings.more, symbol: "ellipsis"), style: .icon)
            view.toolTip = SectionStrings.more
            view.frame = frame
        } else {
            moreView?.removeFromSuperview()
            moreView = nil
        }
        while lineLayers.count > result.separators.count { lineLayers.removeLast().removeFromSuperlayer() }
        while lineLayers.count < result.separators.count {
            let line = CALayer()
            layer?.addSublayer(line)
            lineLayers.append(line)
        }
        for (line, frame) in zip(lineLayers, result.separators) { line.frame = frame }
        accessoryView?.isHidden = result.accessory == nil
        if let frame = result.accessory { accessoryView?.frame = frame }
        CATransaction.commit()
        needsDisplay = true
    }

    private func makeItem(_ id: LayoutItemID) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.isRailButton = true
        view.onPressWithModifiers = { [weak self] flags in
            if let onActivateWithModifiers = self?.onActivateWithModifiers {
                onActivateWithModifiers(id, flags)
            } else {
                self?.onActivate?(id)
            }
        }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        addSubview(view)
        itemViews[id] = view
        return view
    }

    private func makeMore() -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.isRailButton = true
        view.onPress = { [weak self, weak view] in
            guard let self, let view else { return }
            overflowMenu().popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.minY), in: view)
        }
        addSubview(view)
        moreView = view
        return view
    }

    /// The overflowing items, each running what its button would.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for id in layoutResult.overflow {
            let info = content?.infos[id]
                ?? content?.document.item(id).map { SidebarItemInfo.fallback(for: $0.ref) }
                ?? SidebarItemInfo(title: "", symbol: "circle", isMissing: true)
            let item = NSMenuItem(title: info.title, action: #selector(activateOverflowItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func activateOverflowItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onActivate?(LayoutItemID(raw))
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
