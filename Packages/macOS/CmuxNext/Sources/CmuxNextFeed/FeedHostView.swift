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

    /// Where the feed is shown, which decides the ground it paints.
    public enum Surface: Sendable {
        /// A page tab: the pane's fill (`Palette.paneFill`) under the list.
        case page
        /// The Feed panel, a window of its own with no pane under it: the content background.
        case panel
        /// A right sidebar section: no ground of its own, the sidebar's shows through.
        case sidebar
    }

    /// Where this host is shown (``Surface``).
    let surface: Surface
    #if DEBUG
    private var bench: FeedBench?
    #endif

    /// - Parameters:
    ///   - model: The feed.
    ///   - layoutOverride: Pins a prototype (demos and screenshots); nil follows the Debug Settings switch `feed.layout`.
    ///   - surface: Where the feed is shown; a page tab by default.
    ///   - onReportsReply: Sends a reply from the reports basket and answers whether it was sent
    ///     (nil: the basket has no Reply). A reply sent again keeps its ``ReportReply/promptID``.
    public init(model: FeedModel, layoutOverride: FeedLayout? = nil, surface: Surface = .page,
                onReportsReply: (@MainActor (ReportReply) async -> Bool)? = nil) {
        self.model = model
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        let root = FeedRoot(model: model, appearance: appearanceState, layoutOverride: layoutOverride,
                            onReportsReply: onReportsReply)
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
        #if DEBUG
        if window != nil, bench == nil, let settings = FeedBench.Settings(environment: ProcessInfo.processInfo.environment) {
            bench = FeedBench(settings: settings, model: model, host: self)
            bench?.start()
        }
        #endif
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            let background: NSColor = switch surface {
            case .panel: Palette.contentBackground
            case .page: Palette.surfaceOverride(.internalPage) ?? Palette.paneFill
            case .sidebar: .clear
            }
            layer?.backgroundColor = surface == .panel ? background.cgColor : nil
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
