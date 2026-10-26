import AppKit
import CmuxNextDesign

/// Backing for glass overlays that sit over web content. Glass alone picks
/// up the page's colors, which leaves text illegible on bright pages in dark
/// mode, so overlays add a neutral gray veil under their content. The
/// opaque Reduce Transparency fill needs no veil; it shows unchanged.
final class OverlayBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = enclosingOverlayMaterial == .opaque
                ? NSColor.clear.cgColor
                : Palette.elevatedBackground.withAlphaComponent(0.64).cgColor
        }
    }
}
