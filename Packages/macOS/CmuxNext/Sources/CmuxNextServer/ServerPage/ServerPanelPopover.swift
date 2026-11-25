public import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// The menu bar item's popover: the server card page (`cmux.server-cards`) on the server panel,
/// Health or pairing route, made once and kept warm, so a later opening swaps the route and never
/// loads a page. The page drives the popover's size (`cmux.card.resize`, as in ``WebCardPanel``):
/// a route it measured before shows at once at that size; a first opening waits for the page's
/// first size (or ``firstSizeWait``), so the popover never draws at a wrong height and then jumps.
/// A later size (Health opened from the panel, an alert resolved) applies in the same frame, and
/// the popover keeps its edge under the menu bar while its bottom moves.
@MainActor
public final class ServerPanelPopover: NSObject, NSPopoverDelegate {
    static let firstSizeWait: Duration = .milliseconds(400)
    /// The size before the page reports one (the panel's width, a header's height).
    static let initialSize = NSSize(width: 340, height: 120)

    let page: PageWebView
    private let popover = NSPopover()
    private let sizer: Sizer
    /// The last size each route's page reported, in points.
    private var sizes: [String: NSSize] = [:]
    /// The route the popover shows.
    private(set) var route: String?
    /// The route `show` asked for, until the page reports its size.
    private var awaitedRoute: String?
    /// An opening waiting for its route's first size: the button it shows under.
    private var pending: NSView?
    private let firstSize = DemandTimer(owner: "server-panel-first-size")

    public init?(provider: ServerPageProvider) {
        let sizer = Sizer()
        guard let page = PageWebView(descriptor: .serverCards,
                                     routes: [PageRoute(prefix: provider.prefix, provider: provider),
                                              PageRoute(prefix: Sizer.prefix, provider: sizer)],
                                     options: WebCardPanel.engineOptions) else { return nil }
        self.page = page
        self.sizer = sizer
        super.init()
        sizer.owner = self
        let controller = NSViewController()
        controller.view = page
        page.frame = NSRect(origin: .zero, size: Self.initialSize)
        popover.contentViewController = controller
        popover.contentSize = Self.initialSize
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    public var isShown: Bool { popover.isShown }

    /// Shows `route` under `button` (a person's click or the palette).
    public func show(route: String, under button: NSView) {
        // The page on that route already (opened again) reports nothing new: wait for nothing.
        awaitedRoute = route == self.route ? nil : route
        self.route = route
        page.open(route: "/" + route)
        if popover.isShown {
            if let size = sizes[route] { apply(size) }
            return
        }
        if let size = sizes[route] {
            apply(size)
            present(under: button)
            return
        }
        pending = button
        // One deadline per opening; the page's first size or a close ends it.
        firstSize.schedule(after: Self.firstSizeWait) { @MainActor [weak self] in
            guard let self, let button = self.pending else { return }
            self.present(under: button)
        }
    }

    public func close() {
        pending = nil
        firstSize.cancel()
        popover.close()
    }

    /// `cmux.card.resize`: CSS px; the page is zoomed (the interface scale), so one CSS px is
    /// `pageZoom * magnification` points. The page may move between its routes itself (the panel's
    /// Health row), so the size follows whichever route reports.
    fileprivate func pageResized(card: String, width: CGFloat?, height: CGFloat) {
        let zoom = page.webKitView.pageZoom * page.webKitView.magnification
        let size = NSSize(width: ceil((width ?? popover.contentSize.width / zoom) * zoom), height: ceil(height * zoom))
        guard size.height > 0 else { return }
        sizes[card] = size
        // Until the page reports the route `show` asked for, a size from the route before it is
        // kept for that route's next opening, never applied. Once it has, the page may move on its
        // own (the panel's Health row) and its sizes follow (the bridge keeps their order).
        if let expected = awaitedRoute {
            guard card == expected else { return }
            awaitedRoute = nil
        }
        route = card
        apply(size)
        if let button = pending { present(under: button) }
    }

    private func apply(_ size: NSSize) {
        guard abs(size.height - popover.contentSize.height) > 0.5 || abs(size.width - popover.contentSize.width) > 0.5 else { return }
        popover.contentSize = size
    }

    private func present(under button: NSView) {
        pending = nil
        firstSize.cancel()
        popover.show(relativeTo: CmuxPopoverAnchor.rect(in: button), of: button, preferredEdge: .minY)
        page.focusPage()
    }

    /// NSPopover documents no thread for its delegate: inline on main, a hop from anywhere else.
    public nonisolated func popoverDidClose(_ notification: Notification) {
        MainDelivery().run { self.pending = nil }
    }

    /// `cmux.card.*` for the popover: its size and close. Escape closes the popover natively.
    @MainActor
    final class Sizer: PageProvider {
        static let prefix = "cmux.card."
        weak var owner: ServerPanelPopover?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            guard let card = params["card"]?.stringValue, !card.isEmpty else { throw PageError.invalidParams("card is required") }
            switch op {
            case "cmux.card.resize":
                guard let height = params["height"]?.doubleValue, height.isFinite else { throw PageError.invalidParams("height is required") }
                let width = params["width"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
                owner?.pageResized(card: card, width: width, height: CGFloat(height))
            case "cmux.card.close":
                owner?.close()
            default:
                throw PageError.unknownOp(op)
            }
            return .null
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            guard stream == "cmux.card.commands" else { throw PageError.unknownOp(stream) }
            return PageSubscription {}
        }
    }
}
