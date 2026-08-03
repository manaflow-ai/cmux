import AppKit
import QuartzCore

/// Non-hit-testing native color fill for transparent window backdrops.
@MainActor
final class LayerBackedBackdropColor: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setBackdropColor(color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setBackdropColor(_ color: NSColor) {
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = resolvedCGColor(color)
        layer?.isOpaque = color.alphaComponent >= 1
        CATransaction.commit()
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
        }
        return resolved
    }
}
