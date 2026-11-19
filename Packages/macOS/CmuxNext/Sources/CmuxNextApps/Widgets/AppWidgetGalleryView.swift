import AppKit
import CmuxNextDesign

/// The Add Widget gallery's content: a title, then one row per widget (its name, a line about it,
/// and a live preview per size it takes in the sidebar), or a quiet empty state. Laid out by hand,
/// scrolling when it is taller than ``maxHeight``.
final class AppWidgetGalleryView: NSView {
    struct Preview {
        let size: AppWidgetSize
        let mount: AppMount
    }

    struct Row {
        let spec: AppWidgetSpec
        let previews: [Preview]
    }

    /// The gallery's width: two sidebar-sized small tiles side by side with room around them.
    static let width: CGFloat = 320
    static let maxHeight: CGFloat = 520
    /// Runs with the app and size of the preview the person picked.
    var onAdd: ((String, AppWidgetSize) -> Void)?
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let title = ChromeLabel(labelWithString: AppWidgetStrings.galleryTitle)
    private var laidOutHeight: CGFloat = 0
    private let grid = AppWidgetGrid(gap: Metrics.space2, inset: Metrics.space4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = Typography.system(.default, size: TypeScale.title, weight: TypeScale.emphasis)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityIdentifier("cmux.widgets.gallery")
        show([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// The height the popup gives the gallery.
    var preferredHeight: CGFloat { min(Self.maxHeight, laidOutHeight) }

    /// Shows `rows` (none: the empty state).
    func show(_ rows: [Row]) {
        document.subviews.forEach { $0.removeFromSuperview() }
        let width = Self.width
        let inset = Metrics.space4
        var y = inset
        title.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: title.naturalSize.height)
        document.addSubview(title)
        y = title.frame.maxY + Metrics.space3
        if rows.isEmpty {
            for (text, font) in [(AppWidgetStrings.galleryEmpty, Typography.body), (AppWidgetStrings.galleryEmptyHint, Typography.caption)] {
                let label = ChromeLabel(wrappingLabelWithString: text)
                label.font = font
                label.textColor = performWithTheme { font == Typography.body ? Palette.textPrimary : Palette.textSecondary }
                let height = ceil(label.size(forWidth: width - 2 * inset).height)
                label.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: height)
                document.addSubview(label)
                y = label.frame.maxY + Metrics.space1
            }
        }
        for row in rows {
            let name = ChromeLabel(labelWithString: row.spec.title)
            name.font = Typography.header
            name.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: name.naturalSize.height)
            document.addSubview(name)
            y = name.frame.maxY + Metrics.space1
            if let about = row.spec.description, !about.isEmpty {
                let label = ChromeLabel(wrappingLabelWithString: about)
                label.font = Typography.caption
                label.textColor = performWithTheme { Palette.textSecondary }
                label.maximumNumberOfLines = 2
                let height = ceil(label.size(forWidth: width - 2 * inset).height)
                label.frame = CGRect(x: inset, y: y, width: width - 2 * inset, height: height)
                document.addSubview(label)
                y = label.frame.maxY + Metrics.space2
            }
            // Each size on its own row of the sidebar's grid, small first.
            for preview in row.previews {
                let frame = (grid.layout([preview.size], width: width).frames.first ?? .zero).offsetBy(dx: 0, dy: y)
                let tile = AppWidgetPreviewButton(preview: preview, title: row.spec.title)
                tile.onPress = { [weak self] in self?.onAdd?(row.spec.app, preview.size) }
                tile.frame = frame
                document.addSubview(tile)
                y = frame.maxY + Metrics.space2
            }
            y += Metrics.space2
        }
        laidOutHeight = ceil(y + inset - Metrics.space2)
        document.frame = CGRect(x: 0, y: 0, width: width, height: laidOutHeight)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }
}

/// A flipped document view (the gallery's rows run top down).
private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// One gallery preview: the widget's live preview tile, which adds it at its size on a click. Held,
/// it changes only its card's fill (the tile's scene takes no input here).
final class AppWidgetPreviewButton: NSView {
    var onPress: (() -> Void)?
    private let tile: AppWidgetTileView
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }
    private let press = CALayer()

    init(preview: AppWidgetGalleryView.Preview, title: String) {
        tile = AppWidgetTileView(instance: "preview-\(preview.size.rawValue)", mount: preview.mount)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(tile)
        press.cornerCurve = .continuous
        press.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(press)
        let label = AppWidgetStrings.addSized(title, AppWidgetStrings.size(preview.size))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        tile.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        press.frame = bounds
        press.cornerRadius = AppWidgetTileView.cornerRadius
        press.zPosition = 1
        CATransaction.commit()
    }

    override func updateLayer() {
        performWithTheme { press.backgroundColor = isPressed ? Palette.pressedFill.cgColor : NSColor.clear.cgColor }
    }

    /// The preview takes the click, never its scene.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = isPressed
        isPressed = false
        if fire { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
