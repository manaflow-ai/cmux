import AppKit
import CmuxTheme

/// A view a SwiftUI control lays behind itself to learn from the AppKit view tree whether it sits on a menu panel's
/// glass (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``) and in which theme, as each AppKit control finds
/// its own ground (``NSView/buttonGround(_:)``). So SwiftUI content a menu panel hosts fits its inks to the glass with
/// no mark to set or forget (``CmuxPressFillButtonStyle``). It draws nothing, takes no click and is no accessibility
/// element. It is the fallback for content in a plain hosting view, and learns its ground after the frame commit: a
/// ``ThemedHostingView`` gives its content the ground before the first draw.
@MainActor
final class MenuGlassProbeView: NSView {
    /// Called with ``NSView/menuGlassTokens`` each time it changes from the last value reported (nil at first), as the probe
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
