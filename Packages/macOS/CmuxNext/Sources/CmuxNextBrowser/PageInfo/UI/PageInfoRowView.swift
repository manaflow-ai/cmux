import AppKit
import CmuxNextDesign

/// One bubble row (Chromium's `RichHoverButton`) on the shared popup row (``PopupRowView``):
/// icon, title, optional subtitle, and a trailing chevron, external-link mark, or toggle. Gray
/// hover and press fills; keyboard focus draws a gray ring. Space or Return activates, as a click
/// does.
final class PageInfoRowView: PopupRowView {
    enum Accessory {
        case none
        case chevron
        case externalLink
        case toggle(Bool)
    }

    var onToggle: ((Bool) -> Void)? {
        didSet { toggle?.onChange = onToggle }
    }

    private(set) var toggle: PageInfoToggle?

    init(symbol: String?, title: String, subtitle: String? = nil, accessory: Accessory = .none,
         tint: @escaping @autoclosure () -> NSColor? = nil, interactive: Bool = true, identifier: String? = nil) {
        let icon = ThemedImageView()
        icon.image = symbol.flatMap { PageInfoStyle.symbol($0) }
        icon.themeTint = { tint() ?? PageInfoStyle.text }
        let trailing = Self.makeAccessory(accessory)
        var layout = Layout()
        layout.leading = PageInfoStyle.rowInset
        layout.leadingColumn = PageInfoStyle.iconColumn - PageInfoStyle.rowInset
        layout.gap = PageInfoStyle.rowInset
        layout.trailing = PageInfoStyle.rowInset
        layout.trailingGap = PageInfoStyle.rowInset
        let hasSubtitle = !(subtitle?.isEmpty ?? true)
        layout.minHeight = hasSubtitle ? PageInfoStyle.rowHeightWithSubtitle : PageInfoStyle.rowHeight
        super.init(leading: icon, title: title, subtitle: subtitle, trailing: trailing, layout: layout, interactive: interactive)
        toggle = trailing as? PageInfoToggle
        self.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        translatesAutoresizingMaskIntoConstraints = false
        takesFocus = true
        titleLabel.themeColor = { tint() ?? PageInfoStyle.text }
        subtitleLabel.themeColor = { PageInfoStyle.secondaryText }
    }

    private static func makeAccessory(_ accessory: Accessory) -> NSView? {
        switch accessory {
        case .none:
            return nil
        case .chevron, .externalLink:
            let image = ThemedImageView(image: PageInfoStyle.symbol(
                { if case .chevron = accessory { "chevron.right" } else { "arrow.up.forward.square" } }(),
                size: PageInfoStyle.iconSize - 2) ?? NSImage())
            image.themeTint = { PageInfoStyle.secondaryText }
            return image
        case .toggle(let on):
            let toggle = PageInfoToggle()
            toggle.isOn = on
            return toggle
        }
    }

    /// A row with only a toggle flips it; other rows run `onActivate`.
    override func activate() {
        if onActivate == nil, let toggle { toggle.flip() } else { onActivate?() }
    }
}
