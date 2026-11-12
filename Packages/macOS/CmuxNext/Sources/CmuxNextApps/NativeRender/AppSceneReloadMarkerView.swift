import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The line under a kept view whose app's last save did not load (``AppSceneModel/reloadFailure``):
/// a small warning glyph, "Not reloaded" and the `file:line` the error names, in caption type. The
/// view above it keeps drawing the script that last loaded; the whole reason is the tooltip and the
/// accessibility label, so the line stays one row high whatever the error says.
final class AppSceneReloadMarkerView: NSView {
    private let glyph = NSImageView()
    private let label = ChromeLabel(labelWithString: "")
    private let location = ChromeLabel(labelWithString: "")
    private var side: CGFloat { Metrics.smallIconSize }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyph.imageScaling = .scaleProportionallyDown
        glyph.image = NSImage.icon(symbol: "exclamationmark.triangle.fill", size: side)
        label.font = Typography.caption
        label.stringValue = AppsStrings.reloadFailed
        location.font = Typography.system(.monospaced, size: Typography.caption.pointSize)
        for view in [glyph, label, location] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `reason` (the supervisor's init error).
    func show(_ reason: String) {
        let copy = AppFailureCopy(reason: reason)
        location.stringValue = copy.place ?? ""
        location.isHidden = copy.place == nil
        let said = copy.location ?? copy.title
        let spoken = [AppsStrings.reloadFailed, copy.place, said].compactMap { $0 }.joined(separator: ", ")
        toolTip = said
        setAccessibilityLabel(spoken)
        needsLayout = true
        needsDisplay = true
    }

    /// One caption line with its padding above.
    var height: CGFloat { ceil(max(side, label.size(forWidth: .greatestFiniteMagnitude).height)) + Metrics.space1 + Metrics.space2 }

    override func layout() {
        super.layout()
        let lineHeight = height - Metrics.space1 - Metrics.space2
        let top = Metrics.space1
        var x = Metrics.space4
        glyph.frame = CGRect(x: x, y: top + (lineHeight - side) / 2, width: side, height: side).integral
        x = glyph.frame.maxX + Metrics.space1
        let labelWidth = ceil(label.size(forWidth: .greatestFiniteMagnitude).width)
        label.frame = CGRect(x: x, y: top, width: min(labelWidth, max(0, bounds.width - x)), height: lineHeight)
        x = label.frame.maxX + Metrics.space1
        location.frame = CGRect(x: x, y: top, width: max(0, bounds.width - x - Metrics.space4), height: lineHeight)
    }

    override func updateLayer() {
        performWithTheme {
            glyph.contentTintColor = Palette.attention
            label.textColor = Palette.textSecondary
            location.textColor = Palette.textTertiary
        }
    }

    nonisolated override var wantsUpdateLayer: Bool { true }
}
