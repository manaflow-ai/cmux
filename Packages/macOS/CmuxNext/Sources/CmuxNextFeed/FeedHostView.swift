public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the feed panel (variants `list` and `inbox`). The App creates it
/// with a model over its feed sources; demos use `MockFeedSource`. Resolves
/// the panel colors in this view's theme scope and again on every theme or
/// appearance change.
public final class FeedHostView: NSView {
    /// Localized title used by the native Inbox page tab.
    public static var paneTitle: String {
        String(localized: "feed.inboxTitle", defaultValue: "Inbox", bundle: .module)
    }
    public let model: FeedModel
    let appearanceState = FeedAppearance()

    /// `floating`: the host is a panel of its own (the Feed panel), with no
    /// pane under it, so it paints the content background itself; as a page
    /// tab it paints the pane's fill (`Palette.paneFill`).
    let floating: Bool

    /// `layoutOverride` pins a prototype (demos and screenshots); nil
    /// follows the Debug Settings switch `feed.layout`.
    public init(model: FeedModel, layoutOverride: FeedLayout? = nil, floating: Bool = false) {
        self.model = model
        self.floating = floating
        super.init(frame: .zero)
        wantsLayer = true
        let root = FeedRoot(model: model, appearance: appearanceState, layoutOverride: layoutOverride)
        embed(NSHostingView(rootView: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            let background = floating ? Palette.contentBackground : (Palette.surfaceOverride(.internalPage) ?? Palette.paneFill)
            layer?.backgroundColor = floating ? background.cgColor : nil
            return FeedColors.resolved(background: background)
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }
}

extension NSView {
    /// Pins `child` to this view's edges.
    func embed(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
