import AppKit
import CmuxTheme

/// A view a SwiftUI control lays behind itself to learn from the AppKit view tree whether it sits on a menu panel's
/// glass (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``) and in which theme, as each AppKit control finds
/// its own ground (``NSView/buttonGround(_:)``). So SwiftUI content a menu panel hosts fits its inks to the glass with
/// no mark to set or forget (``CmuxPressFillButtonStyle``). It draws nothing, takes no click and is no accessibility
/// element.
@MainActor
final class MenuGlassProbeView: NSView {
    /// Called with ``menuGlassTokens`` each time it changes from the last value reported (nil at first), as the probe
    /// moves in the view tree or its appearance changes. Setting it reports the probe's present ground.
    var onChange: ((ThemeTokens?) -> Void)? {
        didSet { report() }
    }
    private var reported: ThemeTokens?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The theme of the menu panel this view sits on: the nearest overlay surface above it is at the menu level
    /// (``GlassMenuMaterial/level``). Nil off a menu panel. The ink fit to its glass also reads on the panel's opaque
    /// Reduce Transparency surface (``GlassMenuMaterial/ink(_:tokens:minimum:)``), so the material does not matter.
    var menuGlassTokens: ThemeTokens? {
        var current = superview
        while let view = current {
            if let surface = view as? OverlaySurfaceView {
                guard surface.tintLevel == GlassMenuMaterial.level else { return nil }
                return performWithTheme { ThemeContext.active ?? ThemeScope.app.tokens }
            }
            current = view.superview
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        report()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func report() {
        // Nothing is recorded before there is someone to tell: a probe moved before its callback was set reports then.
        guard let onChange else { return }
        let tokens = menuGlassTokens
        guard tokens != reported else { return }
        reported = tokens
        onChange(tokens)
    }
}
