public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups
import SwiftUI

/// Hosts the feed panel (variants `list` and `inbox`). The App creates it
/// with a model over its feed sources; demos use `MockFeedSource`. Resolves
/// the panel colors in this view's theme scope and again on every theme or
/// appearance change.
public final class FeedHostView: NSView, VisibilityGatedContent {
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
    private var gate: VisibilityGatedHostingView?
    /// How many times the colors were resolved (tests: a hidden feed resolves none until it shows).
    private(set) var colorResolves = 0

    /// Its SwiftUI leaves the hierarchy while its tab is hidden (``VisibilityGatedHostingView``). Only a page
    /// tab's node drives it; the panel and the sidebar section never follow one.
    public var visibilityGate: VisibilityGatedHostingView? { gate }

    /// This host in the visibility tree (recipe R-hide, ``ViewVisibility``): under its window's node,
    /// hidden while the host is hidden or in no window. The app polls GitHub only while one feed host's
    /// node is visible. A theme change while it is hidden resolves the colors once, on show.
    private let visibility: ViewVisibility
    public var visibilityNode: VisibilityNode { visibility.node }

    /// - Parameters:
    ///   - model: The feed.
    ///   - layoutOverride: Pins a prototype (demos and screenshots); nil follows the Debug Settings switch `feed.layout`.
    ///   - surface: Where the feed is shown; a page tab by default.
    ///   - mainWork: The app's one main-thread scheduler (the reports basket renders at its frames).
    ///   - surfaces: The feed's surfaces (`FeedService.surfaces`), which count this host's node while it lives.
    ///   - onReportsReply: Sends a reply from the reports basket and answers whether it was sent
    ///     (nil: the basket has no Reply). A reply sent again keeps its ``ReportReply/promptID``.
    public init(model: FeedModel, layoutOverride: FeedLayout? = nil, surface: Surface = .page, mainWork: MainWorkScheduler,
                surfaces: ShownWindows? = nil, onReportsReply: (@MainActor (ReportReply) async -> Bool)? = nil) {
        self.model = model
        self.surface = surface
        visibility = ViewVisibility("feed:\(surface)")
        super.init(frame: .zero)
        surfaces?.track(visibility.node)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = FeedRoot(model: model, appearance: appearanceState, layoutOverride: layoutOverride, mainWork: mainWork,
                            onReportsReply: onReportsReply)
        let gate = VisibilityGatedHostingView(owner: "FeedHostView") { root }
        embed(gate)
        self.gate = gate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The reports basket holds a reply typed and not sent. It lives only in the basket's view; the
    /// inbox's drafts live in the model and outlive this view.
    public var hasTypedReply: Bool { reportsBasket.map { !$0.draft.isEmpty } ?? false }
    /// The reports basket waits on a reply it sent: the retry of a reply that failed keeps its id in
    /// the basket's view.
    public var isSendingReply: Bool { reportsBasket.map { !$0.sending.isEmpty } ?? false }

    /// The reports basket this host shows, if it shows one (first found, breadth first).
    var reportsBasket: ReportsBasketView? {
        var queue: [NSView] = [self]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let basket = next as? ReportsBasketView { return basket }
            queue.append(contentsOf: next.subviewsIncludingGated)
        }
        return nil
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        resolveColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
        resolveColors()
    }

    // R-hide: hiding forwards to the node.
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    // R-appear: the colors feed the SwiftUI feed, so a hidden feed resolves them on show.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferUntilVisible(key: Self.appearanceKey) { [weak self] in self?.resolveColors() }
    }

    private static let appearanceKey = "FeedHostView.appearance"

    private func resolveColors() {
        colorResolves += 1
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
