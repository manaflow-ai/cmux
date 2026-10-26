import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater

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
        UpdateSurfaceIsland(kind: kind, services: services)
    }
}

/// One update surface's page, opened through the app's ``WebUIHost`` and ended through it
/// (``close()``), so the host's lists, the page lifecycle and the crash budgets forget it with its
/// engine page. The sidebar makes one only while its card shows (no page without an update) and
/// closes it when the card goes (dismissed, or the update is gone). No tab shows the page, so it
/// keeps its own key in the page lifecycle (p13-webui.md 3.B, pages without a pane), shown for as
/// long as it lives: the card is on screen, and the parked highlights page runs to load and measure
/// before the first hover.
@MainActor
final class UpdateSurfaceIsland: SidebarSurfaceIsland {
    let view: NSView
    /// The surface's page; nil without app services or when the bundle has no changelog page.
    let page: PageWebView?
    /// The page's key in the page lifecycle; nil without a page.
    let lifecycleKey: String?
    private(set) var contentHeight: CGFloat = 0
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    let provider: UpdateSurfaceProvider
    /// The host that opened ``page``, which ends it.
    private weak var webUI: WebUIHost?

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        let provider = UpdateSurfaceProvider(kind: kind, services: services)
        self.provider = provider
        let page = services.flatMap { PageFactory(services: $0).updateSurfacePage(kind: kind, provider: provider) }
        self.page = page
        view = page ?? NSView()
        webUI = services?.webUI
        lifecycleKey = page.map { "update-surface.\(kind.rawValue).\(ObjectIdentifier($0).hashValue)" }
        provider.onHeight = { [weak self] height in self?.setHeight(height) }
        provider.onAction = { [weak self] in self?.onAction?() }
        provider.onDismiss = { [weak self] in self?.onDismiss?() }
        // The host has a lifecycle only with `pageLifecycle` on (AppMemoryConsumers.installPageLifecycle).
        if let page, let services, let lifecycleKey, let lifecycle = services.webUI.lifecycle {
            let encoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
            lifecycle.show(lifecycleKey, page: PageWebViewLifecycle(page, encoder: encoder))
        }
    }

    /// Ends the page through the host that opened it: its routes, bridge and engine page, and its
    /// place in the host's lists and the page lifecycle. Safe to call twice.
    func close() {
        guard let page else { return }
        if let webUI { webUI.close(page) } else { page.close() }
    }

    /// `height` is in CSS px; the page is zoomed (the interface scale), so
    /// one CSS px is ``PageWebView/pageZoom`` points, in either engine.
    private func setHeight(_ height: CGFloat) {
        let zoom = CGFloat(page?.pageZoom ?? 1)
        let height = max(0, ceil(height * zoom))
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
    var onHeight: ((CGFloat) -> Void)?
    /// The page ran an action (the popover closes).
    var onAction: (() -> Void)?
    /// The card's x: the sidebar sends `.dismissUpdated` (SidebarCardFeed.handle), the one
    /// card-dismiss path; the provider never dismisses on its own.
    var onDismiss: (() -> Void)?

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        self.kind = kind
        self.services = services
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
        // task-owner: the page's subscription; cancelled with it.
        let task = Task { @MainActor [weak self] in
            for await highlights in ObservationStream({ [weak self] in self?.highlights }) {
                guard let self else { return }
                guard let value = try? json(highlights) else { continue }
                services?.updater.log.append("update surface \(kind.rawValue): data \(highlights == nil ? "none" : "\(highlights?.items.count ?? 0) items")")
                onEvent(value)
            }
        }
        // Each event carries the whole highlights value: the newest replaces the rest.
        return PageSubscription(frozenDelivery: .latest) { task.cancel() }
    }
}

extension PageDescriptor {
    /// The sidebar's update surfaces (p13-webui-054): the changelog page's bundle and origin with
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
