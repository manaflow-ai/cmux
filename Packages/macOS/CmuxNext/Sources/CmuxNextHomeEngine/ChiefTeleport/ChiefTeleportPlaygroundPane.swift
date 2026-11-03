#if DEBUG
import AppKit

/// One appearance's half of the Chief Teleport Playground: a window-background fill drawn in its own
/// appearance (light or dark), whatever the app's is.
final class ChiefTeleportPlaygroundPane: NSView {
    init(appearance: NSAppearance.Name) {
        super.init(frame: .zero)
        self.appearance = NSAppearance(named: appearance)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
#endif
