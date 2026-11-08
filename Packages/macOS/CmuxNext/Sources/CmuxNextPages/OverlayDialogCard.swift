import AppKit
import CmuxNextDesign

/// The native card under a dialog's page (``OverlayDialogView``): the sheet surface's glass at the rect
/// the page laid the card out at. Every cmux dialog draws on it: a browser tab's JavaScript alert,
/// confirm, prompt and Leave site? dialog, an HTTP sign-in, and the app's own confirms.
@MainActor
final class OverlayDialogCard: NSView {
    /// The card's material: glass, opaque under Reduce Transparency.
    let glass: OverlaySurfaceView

    init(activeLook: ActiveLookScope?) {
        // The card keeps the key-window glass: its panel gives key back as the close fade starts.
        glass = Glass.makeSurface(.sheet, content: NSView(), activeLook: activeLook)
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        setAccessibilityElement(false)
    }

    /// The layer that casts the card's shadow, behind the glass; nil while it casts none.
    var shadowLayer: CALayer? { nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
