import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// DEV and NIGHTLY (the Debug menu): a browser pane's top: the real tab strip with a trailing group (+, ⌄, ⋮) above a browser
/// toolbar row (Back, Reload, an address field, Extensions, DevTools, ⋮), laid out by a
/// ``TabBarPlaygroundTrailingSpec``. A faint line marks each row's last control center, so a gallery
/// shows whether the two ⋮ share one column.
final class TabBarPlaygroundTrailingRows: NSView {
    private let spec: TabBarPlaygroundTrailingSpec
    private let strip: TabStripView
    private let tabBarButtons: [TitlebarBandButton]
    private let toolbarButtons: [TitlebarBandButton]
    private let navigation: [TitlebarBandButton]
    private let address = NSView()
    private let guide = CALayer()

    init(spec: TabBarPlaygroundTrailingSpec, strip: TabStripView) {
        self.spec = spec
        self.strip = strip
        strip.dragsWindowFromEmptySpace = false
        let plus = TitlebarBandButton(symbol: "plus")
        let chevron = TitlebarBandButton(symbol: "chevron.down")
        chevron.symbolPointSize = { Metrics.smallIconSize - Metrics.space1 }
        tabBarButtons = [plus, chevron] + (spec.tabBarMore.map { [Self.iconButton($0, size: spec.tabBarMoreSize)] } ?? [])
        toolbarButtons = [Self.iconButton(.browserToolbarExtensions, size: spec.toolbarIconSize),
                          Self.iconButton(.browserToolbarDevtools, size: spec.toolbarIconSize)]
            + (spec.toolbarMore.map { [Self.iconButton($0, size: spec.toolbarMoreSize)] } ?? [])
        navigation = [Self.iconButton(.browserToolbarBack, size: spec.toolbarIconSize), Self.iconButton(.browserToolbarReload, size: spec.toolbarIconSize)]
        super.init(frame: .zero)
        wantsLayer = true
        plus.target = self
        plus.action = #selector(newTab)
        address.wantsLayer = true
        address.layer?.cornerRadius = Metrics.tabCornerRadius
        for view in [strip, address] + tabBarButtons + toolbarButtons + navigation as [NSView] { addSubview(view) }
        layer?.addSublayer(guide)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private static func iconButton(_ icon: IconName, size: CGFloat) -> TitlebarBandButton {
        let button = TitlebarBandButton(symbol: icon.rawValue)
        button.customImage = { _, side in NSImage.icon(icon, size: side) }
        button.symbolPointSize = { size }
        return button
    }

    /// The row heights: the tab bar's, then the toolbar's (Helium's button plus its 4 pt padding).
    static var preferredHeight: CGFloat { TabStripView.preferredHeight + Metrics.tokens.toolbarButtonSize + Metrics.space4 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            address.layer?.backgroundColor = Palette.secondarySelectionFill.cgColor
            guide.backgroundColor = NSColor.systemPink.withAlphaComponent(0.35).cgColor
            for button in tabBarButtons + toolbarButtons + navigation { button.contentTintColor = Palette.textSecondary }
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let barHeight = TabStripView.preferredHeight
        // Tab bar: the trailing group from the column leftward, the strip in the rest.
        let side = spec.tabBarButtonSide
        let gap = Metrics.space1 / 2
        var x = width - spec.tabBarColumn + side / 2
        var tabBarColumns: [CGFloat] = []
        for button in tabBarButtons.reversed() {
            let w = button.symbol == "chevron.down" ? Metrics.smallIconSize + Metrics.space2 : side
            button.frame = NSRect(x: x - w, y: ((barHeight - side) / 2).rounded(), width: w, height: side)
            tabBarColumns.append(button.frame.midX)
            x -= w + gap
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(0, x - Metrics.space1), height: barHeight)
        // Toolbar: navigation, the address field, then the trailing buttons from the column leftward.
        let top = barHeight + Metrics.space2
        let button = spec.toolbarButtonSide
        var cursor = Metrics.paneChromeInset
        for item in navigation {
            item.frame = NSRect(x: cursor, y: top, width: button, height: button)
            cursor += button + Metrics.space1
        }
        var trailing = width - spec.toolbarColumn + button / 2
        for (index, item) in toolbarButtons.reversed().enumerated() {
            let center = spec.sharesColumns && index < tabBarColumns.count ? tabBarColumns[index] : trailing - button / 2
            item.frame = NSRect(x: center - button / 2, y: top, width: button, height: button)
            trailing = item.frame.minX - Metrics.space1
        }
        address.frame = NSRect(x: cursor + Metrics.space2, y: top + Metrics.space1, width: max(0, trailing - cursor - Metrics.space4),
                               height: button - Metrics.space2)
        let column = (tabBarButtons.last?.frame.midX ?? toolbarButtons.last?.frame.midX ?? width).rounded()
        guide.frame = CGRect(x: column, y: 0, width: 1, height: bounds.height)
    }

    @objc private func newTab() { strip.model.send(.newTab(after: strip.model.selectedID)) }
}
