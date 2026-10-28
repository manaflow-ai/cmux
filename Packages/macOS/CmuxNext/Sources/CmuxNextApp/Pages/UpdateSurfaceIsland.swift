import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import CmuxNextWakeups

/// The React update surfaces in the sidebar (cx-urd.61.2): the changelog
/// page's bundle, opened on `#/surface/ready` (the staged update's
/// highlights in the card's popover) or `#/surface/updated` (the "cmux
/// Updated!" card). The page reads ``UpdateHighlights`` and sends its
/// buttons back through `cmux.changelog.surface.*`.
@MainActor
final class UpdateSurfaceIslands: SidebarUpdateSurfaces {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland {
        UpdateSurfaceIsland(kind: kind, services: services, release: kind == .ready ? services?.overlayPageRelease : nil)
    }
}

/// One update surface's page, opened through the app's ``WebUIHost`` and ended through it
/// (``close()``), so the host's lists, the page lifecycle and the crash budgets forget it with its
/// engine page. The sidebar makes one only while its card shows (no page without an update) and
/// closes it when the card goes (dismissed, or the update is gone). No tab shows the page, so it
/// keeps its own key in the page lifecycle (p13-webui.md 3.B, pages without a pane), shown for as
/// long as it lives: the card is on screen, and the parked highlights page runs to load and measure
/// before the first hover.
///
/// With feature `memoryOverlayPagesOnFirstUse` the highlights page is an overlay page
/// (``OverlayPageRelease``): no page is made before the first hover, which makes it in the view the
/// card holds and opens the popup once the page measured itself. A measured page waiting unused goes
/// on the App's overlay page planner (its release time, or at memory pressure), and the next hover
/// makes it again the same way.
@MainActor
final class UpdateSurfaceIsland: SidebarSurfaceIsland {
    let view: NSView
    /// The surface's page; nil without app services, when the bundle has no changelog page, once
    /// closed, and under a release before the first hover or while released highlights wait for the next.
    private(set) var page: PageWebView?
    /// The page's key in the page lifecycle; nil without a page.
    private(set) var lifecycleKey: String?
    /// The page's height; 0 until the page measured itself (and again once its page ended).
    private(set) var contentHeight: CGFloat = 0
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    let provider: UpdateSurfaceProvider
    let kind: SidebarUpdateSurfaceKind
    private weak var services: AppServices?
    /// The host that opened ``page``, which ends it.
    private weak var webUI: WebUIHost?
    /// When the parked highlights page goes; nil keeps the page while the card shows.
    private(set) var release: OverlayPageRelease?
    /// Whether ``page`` measured itself: only a measured page is held for the release, so pressure never ends
    /// a page before it could show.
    private var pageMeasured = false

    /// - Parameter terms: The app's overlay page terms for the highlights (`.ready`) page; nil makes the page
    ///   now and keeps it while the card shows.
    init(kind: SidebarUpdateSurfaceKind, services: AppServices?, release terms: OverlayPageReleaseTerms? = nil) {
        // No services (no app): no page subscribes, so a scheduler of its own does nothing.
        let provider = UpdateSurfaceProvider(kind: kind, services: services,
                                             mainWork: services?.mainWork ?? MainWorkScheduler(budget: MainFrameBudget()))
        self.provider = provider
        self.kind = kind
        self.services = services
        webUI = services?.webUI
        let page = terms == nil ? services.flatMap { PageFactory(services: $0).updateSurfacePage(kind: kind, provider: provider) } : nil
        // Under a release the page fills a view of its own, made on the hover inside the view the card holds.
        view = page ?? NSView()
        provider.onHeight = { [weak self] height in self?.setHeight(height) }
        provider.onAction = { [weak self] in self?.onAction?() }
        provider.onDismiss = { [weak self] in self?.onDismiss?() }
        release = terms?.release(owner: "updateHighlights") { [weak self] in self?.endPage() }
        if let page { adopt(page) }
    }

    /// Makes `page` the surface's page, in the page lifecycle under its own key.
    private func adopt(_ page: PageWebView) {
        self.page = page
        pageMeasured = false
        let key = "update-surface.\(kind.rawValue).\(ObjectIdentifier(page).hashValue)"
        lifecycleKey = key
        if page !== view {
            page.frame = view.bounds
            page.autoresizingMask = [.width, .height]
            view.addSubview(page)
        }
        // The host has a lifecycle only with `pageLifecycle` on (AppMemoryConsumers.installPageLifecycle).
        if let services, let lifecycle = services.webUI.lifecycle {
            let encoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
            lifecycle.show(key, page: PageWebViewLifecycle(page, encoder: encoder))
        }
    }

    /// A hover asks for the highlights: under a release, a page not made yet or released is made now; its height
    /// opens the popup.
    func willShow() {
        guard release != nil, page == nil, let services,
              let made = PageFactory(services: services).updateSurfacePage(kind: kind, provider: provider) else { return }
        adopt(made)
    }

    func didShow() { release?.didShow() }

    func didPark() { release?.didHide() }

    /// Ends the page through the host that opened it: its routes, bridge and engine page, and its
    /// place in the host's lists and the page lifecycle. Safe to call twice.
    func close() {
        release?.cancel()
        endPage()
    }

    /// Ends the page (the release's call, or the close); the next hover makes one that measures itself again.
    private func endPage() {
        guard let page else { return }
        self.page = nil
        lifecycleKey = nil
        pageMeasured = false
        contentHeight = 0
        if page !== view { page.removeFromSuperview() }
        if let webUI { webUI.close(page) } else { page.close() }
    }

    /// `height` is in CSS px; the page is zoomed (the interface scale), so
    /// one CSS px is ``PageWebView/pageZoom`` points, in either engine. A page's first height above 0 makes it
    /// the release's to hold.
    private func setHeight(_ height: CGFloat) {
        let zoom = CGFloat(page?.pageZoom ?? 1)
        let height = max(0, ceil(height * zoom))
        if height > 0, page != nil, !pageMeasured {
            pageMeasured = true
            release?.didMake()
        }
        guard height != contentHeight else { return }
        contentHeight = height
        onHeightChange?()
    }
}

/// `cmux.changelog.surface.*`: `get` (the surface's UpdateHighlights or
/// null), `size {height}` (the page's content height), `openChangelog`
/// and `dismiss`; the stream `cmux.changelog.surface.changes` sends the
/// highlights again whenever they change (the notes arrive after staging).
@MainActor
final class UpdateSurfaceProvider: PageProvider {
    /// The surface's ops and stream; ``PageDescriptor/updateSurface`` lists exactly these.
    static let getOp = "cmux.changelog.surface.get"
    static let sizeOp = "cmux.changelog.surface.size"
    static let openChangelogOp = "cmux.changelog.surface.openChangelog"
    static let dismissOp = "cmux.changelog.surface.dismiss"
    static let changesStream = "cmux.changelog.surface.changes"

    let kind: SidebarUpdateSurfaceKind
    private weak var services: AppServices?
    /// The app's main-thread scheduler, held strongly: the changes stream flushes on it even after
    /// `services` is gone.
    private let mainWork: MainWorkScheduler
    var onHeight: ((CGFloat) -> Void)?
    /// The page ran an action (the popover closes).
    var onAction: (() -> Void)?
    /// The card's x: the sidebar sends `.dismissUpdated` (SidebarCardFeed.handle), the one
    /// card-dismiss path; the provider never dismisses on its own.
    var onDismiss: (() -> Void)?

    /// - Parameter mainWork: The app's main-thread scheduler (`AppServices.mainWork`).
    init(kind: SidebarUpdateSurfaceKind, services: AppServices?, mainWork: MainWorkScheduler) {
        self.kind = kind
        self.services = services
        self.mainWork = mainWork
    }

    private var highlights: UpdateHighlights? {
        guard let updater = services?.updater else { return nil }
        guard kind == .updated else { return updater.stagedHighlights }
        return updater.lastUpdateHighlights ?? updater.updatedWithoutRecordHighlights
    }

    private func json(_ highlights: UpdateHighlights?) throws -> JSONValue {
        guard let highlights else { return .null }
        return try JSONValue.parse(JSONEncoder().encode(highlights))
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == Self.dismissOp {
            onDismiss?()
            return .null
        }
        guard let services else { throw PageError.unknownOp(op) }
        switch op {
        case Self.getOp:
            return try json(highlights)
        case Self.sizeOp:
            guard let height = params["height"]?.doubleValue else { throw PageError.invalidParams("height is required") }
            services.updater.log.append("update surface \(kind.rawValue): height \(Int(height))")
            onHeight?(CGFloat(height))
            return .null
        case Self.openChangelogOp:
            _ = kind == .ready ? services.updater.openStagedChangelog() : services.updater.openWhatsNewForLastUpdate()
            onAction?()
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let mainWork = mainWork
        // The page's router holds events while the page is hidden: a service observation, one flush per
        // frame. The stream starts with the current highlights, sent in a posted task after the subscribe
        // returned; the value applied inside `init` is that one.
        let subscribed = PageStreamStart()
        let observation = ServiceObservation(.visible, owner: "update-surface.changes", on: mainWork) { [weak self] in
            self?.highlights
        } apply: { [weak self] highlights in
            if subscribed.isDone { self?.send(highlights, onEvent) }
        }
        subscribed.finish()
        mainWork.post(.visible, owner: "update-surface.changes") { [weak self] in
            guard let self, !observation.isCancelled else { return }
            send(highlights, onEvent)
        }
        // Each event carries the whole highlights value: the newest replaces the rest.
        return PageSubscription(frozenDelivery: .latest) { observation.cancel() }
    }

    private func send(_ highlights: UpdateHighlights?, _ onEvent: @MainActor (JSONValue) -> Void) {
        guard let value = try? json(highlights) else { return }
        services?.updater.log.append("update surface \(kind.rawValue): data \(highlights == nil ? "none" : "\(highlights?.items.count ?? 0) items")")
        onEvent(value)
    }
}

extension PageDescriptor {
    /// The sidebar's update surfaces: the changelog page's bundle and origin with
    /// only what a card uses, so the card is app content and opens in the `privileged` group, never
    /// in a WebKit process of its own (p13-webui.md 3.F). Its ops are the surface's own
    /// (``UpdateSurfaceProvider``) and the signed notes' `list`, `get` and `reel` (null: the card's
    /// notes have no media store). No native op, no pull request link card, and the strict CSP: the
    /// only pictures are the `data:` images the host inlines and checks.
    static let updateSurface = PageDescriptor(
        id: PageDescriptor.changelog.id, resource: PageDescriptor.changelog.resource, processGroup: .privileged,
        namespaces: ["cmux.changelog."],
        opTables: [PageOpTable(namespace: "cmux.changelog.",
                               read: ["surface.get", "surface.size", "surface.changes", "list", "get", "reel"],
                               act: ["surface.openChangelog", "surface.dismiss"])])
}

extension PageFactory {
    /// One update surface: the changelog bundle on `#/surface/<kind>` as ``PageDescriptor/updateSurface``,
    /// its `cmux.changelog.surface.` ops to `provider`, and the notes' `list`, `get` and `reel` to the
    /// page's verified notes, so the Updated card sums up every build the update spans. The card
    /// shows no pictures: no media inlining.
    func updateSurfacePage(kind: SidebarUpdateSurfaceKind, provider: UpdateSurfaceProvider) -> PageWebView? {
        // PageRouter tries the longest prefix first: the surface's own ops before the notes.
        let routes = [PageRoute(prefix: "cmux.changelog.surface.", provider: provider),
                      PageRoute(prefix: "cmux.changelog.", provider: changelogNotes())]
        // The island floats over the window's backdrop: a Chromium page cannot be transparent.
        // Window chrome: a first click on See What's New acts while a Chromium page's window has the key.
        return services.webUI.open(PageOpenRequest(descriptor: .updateSurface, routes: routes, route: "#/surface/\(kind.rawValue)",
                                                   options: PageEngineOptions(requiresWebKit: .transparentOverlay,
                                                                              acceptsFirstMouse: true)))
    }
}
