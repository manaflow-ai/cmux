import AppKit
import CmuxNextDesign
import QuartzCore

/// Floating gray pill under the active row. One instance glides between rows.
final class SelectionPillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Metrics.space1
        layer?.shadowOffset = CGSize(width: 0, height: -Metrics.space1 / 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(Palette.selectionFill)
        layer?.borderColor = resolvedCGColor(SidebarStyle.pillRim)
        layer?.shadowColor = NSColor(white: 0, alpha: 0.10).cgColor
    }
}

/// Placeholder drawn inside the open drag gap.
final class GapIndicatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(Palette.hoverFill)
        layer?.borderColor = resolvedCGColor(Palette.separator)
    }
}
