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

    /// `layoutOverride` pins a prototype (demos and screenshots); nil
    /// follows the Debug Settings switch `feed.layout`.
    public init(model: FeedModel, layoutOverride: FeedLayout? = nil) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        let root = FeedRoot(model: model, appearance: appearanceState, layoutOverride: layoutOverride)
        embed(NSHostingView(rootView: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var wantsUpdateLayer: Bool { true }

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
            layer?.backgroundColor = Palette.contentBackground.cgColor
            return FeedColors.resolved(background: Palette.contentBackground)
        }
        if appearanceState.colors != colors { appearanceState.colors = colors }
    }
}

/// Hosts the menu bar variant (`feed.menubar = compact`) at the popover
/// width. In an `NSPopover` the popover draws the material; with
/// `backdrop`, the view draws its own (Liquid Glass, a blur before macOS 26,
/// an opaque fill under Reduce Transparency) for a plain window.
public final class FeedMenubarHostView: NSView {
    public let model: FeedModel
    private let appearanceState = FeedAppearance()
    private let surface: OverlaySurfaceView?
    private let hosting: NSHostingView<FeedMenubarRoot>

    public init(model: FeedModel, backdrop: Bool = false) {
        self.model = model
        surface = backdrop ? OverlaySurfaceView() : nil
        let root = FeedMenubarRoot(model: model, appearance: appearanceState)
        hosting = NSHostingView(rootView: root)
        super.init(frame: NSRect(x: 0, y: 0, width: FeedTunables.menubarWidth.value, height: 320))
        if let surface {
            surface.cornerRadius = 14
            embed(surface)
            hosting.frame = surface.contentView.bounds
            hosting.autoresizingMask = [.width, .height]
            surface.contentView.addSubview(hosting)
        } else {
            embed(hosting)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The popover's content size: fixed width, height from the rows.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: FeedTunables.menubarWidth.value, height: NSView.noIntrinsicMetric)
    }

    /// The size the rows need: set it as the popover's `contentSize` after
    /// the model changes.
    public var preferredContentSize: NSSize {
        NSSize(width: FeedTunables.menubarWidth.value, height: hosting.fittingSize.height)
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
        let colors = performWithTheme { FeedColors.resolved(background: Palette.elevatedBackground) }
        surface?.applyTheme()
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
