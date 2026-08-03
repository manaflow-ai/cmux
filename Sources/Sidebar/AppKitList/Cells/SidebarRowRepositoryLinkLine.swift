import AppKit

/// One repository row: hosting icon + one-line underlined repository name.
@MainActor
final class SidebarRowRepositoryLinkLine: NSView {
    private let iconView = NSImageView()
    private let linkButton = SidebarRowLinkButton()
    private var iconSide: CGFloat = 0
    private var lineHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        linkButton.lineBreakMode = .byTruncatingTail
        linkButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iconView)
        addSubview(linkButton)
        setAccessibilityIdentifier("SidebarRepositoryLinkRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        display: SidebarWorkspaceSnapshotBuilder.RepositoryLinkDisplay,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        onOpen: @escaping (URL) -> Void
    ) {
        iconSide = model.scaled(9) + 3
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "shippingbox",
            pointSize: model.scaled(9),
            weight: nil
        )
        iconView.contentTintColor = palette.secondary(0.75)

        let font = NSFont.systemFont(ofSize: model.scaled(10), weight: .regular)
        let tooltip = display.openTooltip
        linkButton.configure(
            title: display.displayName,
            font: font,
            color: palette.secondary(0.75),
            underlined: true,
            toolTip: tooltip
        ) {
            onOpen(display.url)
        }
        linkButton.setAccessibilityLabel(tooltip)
        setAccessibilityLabel(tooltip)
        lineHeight = max(iconSide, ceil(font.ascender - font.descender + font.leading))
        needsLayout = true
    }

    func measuredHeight(width _: CGFloat) -> CGFloat {
        lineHeight
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(
            x: 0,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )
        let buttonX = iconSide + 4
        linkButton.frame = NSRect(
            x: buttonX,
            y: 0,
            width: max(10, bounds.width - buttonX),
            height: bounds.height
        )
    }
}
