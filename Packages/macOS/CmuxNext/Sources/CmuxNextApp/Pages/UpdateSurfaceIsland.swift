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

@MainActor
final class UpdateSurfaceIsland: SidebarSurfaceIsland {
    let view: NSView
    private(set) var contentHeight: CGFloat = 0
    private(set) var contentWidth: CGFloat = 0
    /// The page has reported a size: its first report reaches the host even when it is 0 (a page with nothing to show).
    private var reported = false
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    let provider: UpdateSurfaceProvider

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        let provider = UpdateSurfaceProvider(kind: kind, services: services)
        self.provider = provider
        view = services.flatMap { PageFactory(services: $0).updateSurfacePage(kind: kind, provider: provider) } ?? NSView()
        provider.onSize = { [weak self] height, width in self?.setSize(height: height, width: width) }
        provider.onAction = { [weak self] in self?.onAction?() }
        provider.onDismiss = { [weak self] in self?.onDismiss?() }
    }

    func close() {
        (view as? PageWebView)?.close()
    }

    /// `height` and `width` are in CSS px; the page is zoomed (the interface scale), so
    /// one CSS px is `pageZoom * magnification` points. A width of 0: the page fills its host.
    private func setSize(height: CGFloat, width: CGFloat) {
        let zoom = ((view as? PageWebView)?.webKitView).map { $0.pageZoom * $0.magnification } ?? 1
        let height = max(0, ceil(height * zoom)), width = max(0, ceil(width * zoom))
        guard height != contentHeight || width != contentWidth || !reported else { return }
        (contentHeight, contentWidth, reported) = (height, width, true)
        onHeightChange?()
    }
}

/// `cmux.changelog.surface.*`: `get` (the surface's UpdateHighlights or
/// null), `size {height, width?}` (the page's content height, and its own width when it is
/// narrower than the host), `openChangelog`
/// and `dismiss`; the stream `cmux.changelog.surface.changes` sends the
/// highlights again whenever they change (the notes arrive after staging).
@MainActor
final class UpdateSurfaceProvider: PageProvider {
    let kind: SidebarUpdateSurfaceKind
    private weak var services: AppServices?
    /// The page's content height and its own width (0: it fills the host), in CSS px.
    var onSize: ((CGFloat, CGFloat) -> Void)?
    /// The page ran an action (the popover closes).
    var onAction: (() -> Void)?
    /// The card's x: the sidebar sends `.dismissUpdated` (SidebarCardFeed.handle), the one
    /// card-dismiss path; the provider never dismisses on its own.
    var onDismiss: (() -> Void)?

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        self.kind = kind
        self.services = services
    }

    private var highlights: UpdateHighlights? { services?.updater.surfaceHighlights(updated: kind == .updated) }

    /// The Updated card after an automatic install that relaunched cmux behind another app says so.
    private func json(_ highlights: UpdateHighlights?) throws -> JSONValue {
        try highlights?.surfaceJSON(background: kind == .updated && services?.environment.relaunchBehind != nil) ?? .null
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == "cmux.changelog.surface.dismiss" {
            onDismiss?()
            return .null
        }
        guard let services else { throw PageError.unknownOp(op) }
        switch op {
        case "cmux.changelog.surface.get":
            return try json(highlights)
        case "cmux.changelog.surface.size":
            guard let height = params["height"]?.doubleValue else { throw PageError.invalidParams("height is required") }
            services.updater.log.append("update surface \(kind.rawValue): height \(Int(height))")
            onSize?(CGFloat(height), CGFloat(params["width"]?.doubleValue ?? 0))
            return .null
        case "cmux.changelog.surface.openChangelog":
            _ = kind == .ready ? services.updater.openStagedChangelog() : services.updater.openWhatsNewForLastUpdate()
            onAction?()
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.changelog.surface.changes" else { throw PageError.unknownOp(stream) }
        // task-owner: the page's subscription; cancelled with it.
        let task = Task { @MainActor [weak self] in
            for await highlights in ObservationStream({ [weak self] in self?.highlights }) {
                guard let self else { return }
                guard let value = try? json(highlights) else { continue }
                services?.updater.log.append("update surface \(kind.rawValue): data \(highlights == nil ? "none" : "\(highlights?.items.count ?? 0) items")")
                onEvent(value)
            }
        }
        return PageSubscription { task.cancel() }
    }
}

extension PageFactory {
    /// One update surface: the changelog bundle on `#/surface/<kind>`, its
    /// `cmux.changelog.surface.` ops to `provider`, and the other `cmux.changelog.` ops
    /// (`list`, `get`, a PR chip's `pr.inspect`, `browser.list` and `browser.openIn`) to the
    /// page's verified notes, so the Updated card sums up every build the update spans. The card shows no pictures: no media inlining.
    func updateSurfacePage(kind: SidebarUpdateSurfaceKind, provider: UpdateSurfaceProvider) -> PageWebView? {
        let native = AppPageNativeProvider(services: services, page: .changelog)
        // PageRouter tries the longest prefix first: the surface's own ops before the notes.
        let notes = changelogNotes()
        let routes = [PageRoute(prefix: "cmux.changelog.surface.", provider: provider), PageRoute(prefix: "cmux.changelog.", provider: notes), PageRoute(prefix: "cmux.app.", provider: native)]
        // The island floats over the window's backdrop: a Chromium page cannot be transparent.
        // Window chrome: a first click on See What's New acts while a Chromium page's window has the key.
        let page = PageWebView(descriptor: .changelog, routes: routes, route: "#/surface/\(kind.rawValue)",
                               options: PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true))
        native.anchor = { [weak page] in page }
        notes.anchor = { [weak page] in page }
        return page
    }
}
