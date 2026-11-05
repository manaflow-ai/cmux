import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): one candidate for the tab bar's new-tab control (Lawrence msg 19605: "plus with down
/// chevron is not good at all"), built from the chrome's real buttons (``TitlebarBandButton``): the
/// same hover, press and menu as the shipped control. A press on a + opens a tab in its row's strip;
/// a menu lists the kinds of tab.
final class TabBarPlaygroundNewTabControl: NSView {
    enum Style: CaseIterable {
        /// A plain +; the kinds of tab on right-click or hold.
        case plusOnly
        /// A + that opens the kinds of tab on a click.
        case plusOpensMenu
        /// A + and a ⌄ that shows only while the pointer is on the control.
        case chevronOnHover
        /// A + and a small ⌄ badge in its corner (the hold menu, shown).
        case cornerBadge
        /// A + in a filled rounded square, Safari's new tab.
        case filledPlus
        /// "+ New Tab", the + with its label.
        case labeled
        /// The ⌄ before the +.
        case chevronFirst
        /// + and ⌄ in one segmented capsule, a hairline between them.
        case segmented
        /// A larger +, Helium's 28 pt toolbar button.
        case largePlus
    }

    private let style: Style
    private let model: TabStripModel
    private let plus: TitlebarBandButton
    private var chevron: TitlebarBandButton?
    private var tracking: NSTrackingArea?

    init(style: Style, model: TabStripModel) {
        self.style = style
        self.model = model
        plus = TitlebarBandButton(symbol: "plus", text: style == .labeled ? Strings.axNewTab : nil)
        super.init(frame: .zero)
        wantsLayer = true
        plus.target = self
        plus.action = #selector(newTab)
        plus.menuProvider = { [weak self] in self?.kindsMenu() }
        if style == .plusOpensMenu { plus.pressMenu = { [weak self] in self?.kindsMenu() } }
        addSubview(plus)
        if [.chevronOnHover, .chevronFirst, .segmented, .cornerBadge].contains(style) {
            let chevron = TitlebarBandButton(symbol: "chevron.down")
            chevron.symbolPointSize = { style == .cornerBadge ? Metrics.space4 : Metrics.smallIconSize - Metrics.space1 }
            chevron.pressMenu = { [weak self] in self?.kindsMenu() }
            if style == .chevronOnHover { chevron.alphaValue = 0 }
            addSubview(chevron)
            self.chevron = chevron
        }
        if style == .filledPlus || style == .segmented {
            layer?.cornerRadius = Metrics.tabCornerRadius
            layer?.backgroundColor = performWithTheme { Palette.secondarySelectionFill.cgColor }
        }
        if style == .largePlus { plus.symbolPointSize = { Metrics.iconSize + Metrics.space1 } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The control's width in the bar.
    var preferredWidth: CGFloat {
        let side = TitlebarBandButton.side
        return switch style {
        case .plusOnly, .plusOpensMenu, .filledPlus: side + Metrics.space2
        case .largePlus: side + Metrics.space4
        case .cornerBadge: side + Metrics.space2
        case .labeled: plus.preferredWidth + Metrics.space2
        case .chevronOnHover, .chevronFirst, .segmented: side + Metrics.smallIconSize + Metrics.space4
        }
    }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        let y = ((bounds.height - side) / 2).rounded()
        let chevronWidth = Metrics.smallIconSize + Metrics.space2
        switch style {
        case .chevronFirst:
            chevron?.frame = NSRect(x: Metrics.space1, y: y, width: chevronWidth, height: side)
            plus.frame = NSRect(x: Metrics.space1 + chevronWidth, y: y, width: side, height: side)
        case .chevronOnHover, .segmented:
            plus.frame = NSRect(x: Metrics.space1, y: y, width: side, height: side)
            chevron?.frame = NSRect(x: Metrics.space1 + side, y: y, width: chevronWidth, height: side)
        case .cornerBadge:
            plus.frame = NSRect(x: Metrics.space1, y: y, width: side, height: side)
            let badge = Metrics.space5
            chevron?.frame = NSRect(x: plus.frame.maxX - badge + Metrics.space1, y: y, width: badge, height: badge)
        case .labeled:
            plus.frame = NSRect(x: Metrics.space1, y: y, width: plus.preferredWidth, height: side)
        case .largePlus:
            let large = side + Metrics.space2
            plus.frame = NSRect(x: Metrics.space1, y: ((bounds.height - large) / 2).rounded(), width: large, height: large)
        case .plusOnly, .plusOpensMenu, .filledPlus:
            plus.frame = NSRect(x: Metrics.space1, y: y, width: side, height: side)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard style == .chevronOnHover else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { chevron?.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { chevron?.alphaValue = 0 }

    @objc private func newTab() { model.send(.newTab(after: model.selectedID)) }

    /// The kinds of tab, as the shipped chooser lists them.
    private func kindsMenu() -> NSMenu {
        let menu = NSMenu()
        for title in [Strings.playgroundTerminal, Strings.playgroundBrowser, Strings.playgroundAgentChat] {
            let item = NSMenuItem(title: title, action: #selector(newTab), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
}
