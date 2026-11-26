import AppKit

/// One theme's column of the Tooltip Gallery: a stand-in page in that theme, each ``TooltipGallerySample`` drawn
/// under a stand-in control, then a live toolbar whose buttons carry real themed tooltips (hover one, then its
/// neighbours: the first waits the hover delay, the rest show at once while the group is warm).
@MainActor
final class TooltipGallerySheet: NSView {
    let title: String
    private let scope = ThemeScope(level: .room)
    private(set) var tooltips: [TooltipGalleryTooltip] = []
    private(set) var liveButtons: [NSButton] = []

    /// - Parameters:
    ///   - title: The column's name.
    ///   - isDark: Draws in the dark appearance.
    ///   - theme: The theme's name and colors; nil keeps the app's.
    init(title: String, isDark: Bool, theme: (spec: ThemeSpec?, input: ThemeInput)?) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // concentric-allow: the gallery's stand-in page behind the samples, not a container of buttons.
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.masksToBounds = true
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if let theme { scope.setOverride(theme.spec, input: theme.input, animated: false) }
        scope.root(self)
        setAccessibilityIdentifier("cmux.tooltipGallery.\(title.lowercased())")
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = performWithTheme { Palette.windowBackground }.cgColor
    }

    private func build() {
        var rows: [NSView] = []
        for sample in TooltipGallerySample.all {
            let name = ThemedLabel(labelWithString: sample.name)
            name.font = Typography.caption
            name.themeColor = { Palette.textTertiary }
            let tooltip = TooltipGalleryTooltip(sample)
            tooltip.setAccessibilityIdentifier("cmux.tooltipGallery.\(title.lowercased()).\(tooltips.count)")
            tooltips.append(tooltip)
            let stack = NSStackView(views: [name, tooltip])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            rows.append(stack)
        }
        let live = ThemedLabel(labelWithString: "Live: hover a button, then its neighbours")
        live.font = Typography.caption
        live.themeColor = { Palette.textTertiary }
        let samples: [(symbol: String, label: String, shortcut: String?)] = [
            ("chevron.left", "Back", "⌘["), ("chevron.right", "Forward", "⌘]"), ("xmark", "Close Tab", "⌘W"),
            ("magnifyingglass", "Find", "⌘F"), ("sidebar.left", "Toggle Sidebar", nil),
        ]
        let buttons = samples.map { sample -> NSView in
            let image = NSImage(systemSymbolName: sample.symbol, accessibilityDescription: sample.label) ?? NSImage()
            let button = NSButton(image: image, target: nil, action: nil)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(sample.label)
            button.themedToolTip = sample.label
            button.themedToolTipShortcut = sample.shortcut
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            liveButtons.append(button)
            return button
        }
        let toolbar = NSStackView(views: buttons)
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        rows += [live, toolbar]
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
