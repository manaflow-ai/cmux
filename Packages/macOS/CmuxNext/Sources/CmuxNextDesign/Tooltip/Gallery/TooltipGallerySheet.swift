import AppKit
import CmuxNextDesignTokens

/// One theme's column of the Tooltip Gallery: a stand-in page in that theme, each ``TooltipGallerySample`` drawn
/// under a stand-in control, then a live toolbar whose buttons carry real themed tooltips (hover one, then its
/// neighbours: the first waits the hover delay, the rest show at once while the group is warm).
@MainActor
final class TooltipGallerySheet: NSView {
    let title: String
    private let scope = ThemeScope(level: .room)
    private(set) var tooltips: [TooltipGalleryTooltip] = []
    private(set) var liveButtons: [NSButton] = []
    /// The hover surface variants (``HoverSurfaceLook/solidLooks``), each over a plain and a busy
    /// terminal-like backdrop, in that order.
    private(set) var hoverSurfaces: [(look: HoverSurfaceLook, busy: Bool, tooltip: TooltipGalleryTooltip)] = []

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
        rows += hoverSurfaceRows()
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

    /// Leo 2026-11-24: "wack ass glass". The three solid hover surface variants side by side, each over a
    /// plain page and over a busy terminal, so the text's contrast shows on both (the setting ships 1).
    private func hoverSurfaceRows() -> [NSView] {
        let heading = ThemedLabel(labelWithString: "Hover surface: plain and over a terminal")
        heading.font = Typography.caption
        heading.themeColor = { Palette.textTertiary }
        var rows: [NSView] = [heading]
        let sample = TooltipGallerySample(name: "", text: "Reopen Closed Tab", shortcut: "⇧⌘T")
        for look in HoverSurfaceLook.solidLooks {
            let name = ThemedLabel(labelWithString: look.tunableTitle + (look == HoverSurfaceLook.tunable.defaultValue ? " (default)" : ""))
            name.font = Typography.caption
            name.themeColor = { Palette.textTertiary }
            let tiles = [false, true].map { busy -> NSView in
                let tooltip = TooltipGalleryTooltip(sample, look: look)
                tooltip.setAccessibilityIdentifier("cmux.tooltipGallery.\(title.lowercased()).hover.\(look.rawValue).\(busy ? "busy" : "plain")")
                hoverSurfaces.append((look, busy, tooltip))
                return TooltipGalleryBackdrop(busy: busy, holding: tooltip)
            }
            let pair = NSStackView(views: tiles)
            pair.orientation = .horizontal
            pair.spacing = 8
            let stack = NSStackView(views: [name, pair])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            rows.append(stack)
        }
        return rows
    }
}

/// A tile behind one gallery tooltip: the page's plain background, or a busy terminal (monospaced lines in the
/// theme's terminal colors), the ground a hint toast or a tab's tooltip most often sits on.
@MainActor
final class TooltipGalleryBackdrop: NSView {
    let busy: Bool

    init(busy: Bool, holding tooltip: NSView) {
        self.busy = busy
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // concentric-allow: a stand-in backdrop tile, not a container of buttons.
        layer?.cornerRadius = Metrics.space2
        layer?.masksToBounds = true
        addSubview(tooltip)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200),
            heightAnchor.constraint(equalToConstant: 64),
            tooltip.centerXAnchor.constraint(equalTo: centerXAnchor),
            tooltip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override var isFlipped: Bool { true }

    /// Terminal-like output under the tooltip: dense, colored, edge to edge.
    private static let lines = [
        "$ cargo test -p cmux-layout-reducer",
        "   Compiling cmux-tui v0.1.0 (/src/cmux-tui)",
        "test sidebar_face::tab_kind ... ok",
        "test reducer::hover_anchor ... FAILED",
        "warning: unused variable `anchor`",
        "  --> src/hover.rs:42:9 | let anchor = rect;",
        "error[E0308]: mismatched types",
        "drwxr-xr-x  12 cmux staff  384 Nov 24 04:40 .",
    ]

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.windowBackground.setFill()
            bounds.fill()
            guard busy else { return }
            let font = Typography.system(.monospaced, size: TypeScale.caption)
            let inks = [Palette.textPrimary, NSColor.systemGreen, NSColor.systemRed, NSColor.systemYellow, Palette.textSecondary, NSColor.systemBlue]
            for (index, line) in Self.lines.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inks[index % inks.count]]
                (line as NSString).draw(at: NSPoint(x: 4, y: 2 + CGFloat(index) * (font.pointSize + 1)), withAttributes: attributes)
            }
        }
    }
}
