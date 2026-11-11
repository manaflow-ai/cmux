import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater

/// The React update surfaces in the sidebar (cx-urd.61.2): the changelog page's bundle, opened on
/// `#/surface/ready` (the staged update's highlights), `#/surface/updated` (the "cmux Updated!"
/// card) or `#/surface/updated-notes` (its changes in a popover). The page reads
/// ``UpdateHighlights`` and sends its buttons back through `cmux.changelog.surface.*`.
@MainActor
final class UpdateSurfaceIslands: SidebarUpdateSurfaces {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland { UpdateSurfaceIsland(kind: kind, services: services) }
}

@MainActor
final class UpdateSurfaceIsland: SidebarSurfaceIsland {
    let view: NSView
    /// The page's last size report; its first one reaches the host even when it is 0.
    private var size = PageSurfaceSize()
    var contentHeight: CGFloat { size.height }
    var contentWidth: CGFloat { size.width }
    var overlayHeight: CGFloat { size.overlay }
    var previewHeight: CGFloat { size.preview }
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDrag: ((SidebarCardDrag) -> Void)?
    let provider: UpdateSurfaceProvider
    var zoom: CGFloat { ((view as? PageWebView)?.webKitView).map { $0.pageZoom * $0.magnification } ?? 1 }

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        let provider = UpdateSurfaceProvider(kind: kind, services: services)
        self.provider = provider
        view = services.flatMap { PageFactory(services: $0).updateSurfacePage(kind: kind, provider: provider) } ?? NSView()
        provider.onSize = { [weak self] h, w, overlay, preview in self?.resize { $0.take(height: h, width: w, overlay: overlay, preview: preview, zoom: $1) } }
        (view as? PageWebView)?.onZoomChange = { [weak self] in self?.resize { $0.rezoom($1) } }
        provider.card.zoom = { [weak self] in self?.zoom ?? 1 }
        provider.card.onDrag = { [weak self] in self?.onDrag?(SidebarCardDrag(offset: $0, drop: $1.flatMap(SidebarCardAnchor.init(rawValue:)))) }
        provider.onAction = { [weak self] in self?.onAction?() }
        provider.onDismiss = { [weak self] in self?.onDismiss?() }
    }

    /// Applies a size change at the page's zoom; the sidebar lays the card out again when it changed.
    private func resize(_ change: (inout PageSurfaceSize, CGFloat) -> Bool) { if change(&size, zoom) { onHeightChange?() } }
    func close() { (view as? PageWebView)?.close() }
    func setPointerInside(_ inside: Bool) { provider.pointer.value = inside }
    func setPlace(_ place: SidebarCardPlace) { provider.card.setPlace(anchor: place.anchor.rawValue, above: place.above, below: place.below) }
}

/// `cmux.changelog.surface.*`: `get` (the surface's UpdateHighlights or null), `size {height, width?, overlay?, preview?}`
/// (CSS px, ``PageSurfaceSize``), `openChangelog` and `dismiss`;
/// `cmux.changelog.surface.changes` resends the highlights on each change, `.pointer` the host's pointer;
/// `.card.*` is the Updated card's drag (``PageCardDrag``).
@MainActor
final class UpdateSurfaceProvider: PageProvider {
    let kind: SidebarUpdateSurfaceKind
    private weak var services: AppServices?
    /// The page's content height, its own width (0: fills the host), its preview's room and open height, CSS px.
    var onSize: ((CGFloat, CGFloat, CGFloat, CGFloat) -> Void)?
    /// The pointer is on the Updated card (the sidebar host's tracking area), streamed to the page.
    let pointer = PageFlagStream(key: "inside")
    let card = PageCardDrag(prefix: "cmux.changelog.surface.card.")
    /// The page ran an action (the popover closes).
    var onAction: (() -> Void)?
    /// The card's x: the sidebar sends `.dismissUpdated` (SidebarCardFeed.handle), the one
    /// card-dismiss path; the provider never dismisses on its own.
    var onDismiss: (() -> Void)?

    init(kind: SidebarUpdateSurfaceKind, services: AppServices?) {
        self.kind = kind
        self.services = services
    }

    private var highlights: UpdateHighlights? { services?.updater.surfaceHighlights(updated: kind.showsLastUpdate) }

    /// The Updated card after an automatic install that relaunched cmux behind another app says so.
    private func json(_ highlights: UpdateHighlights?) throws -> JSONValue {
        try highlights == nil ? .null : services?.updater.surfaceJSON(updated: kind.showsLastUpdate, background: kind.showsLastUpdate && services?.environment.relaunchBehind != nil) ?? .null
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == "cmux.changelog.surface.dismiss" { onDismiss?(); return .null }
        guard let services else { throw PageError.unknownOp(op) }
        switch op {
        case "cmux.changelog.surface.get":
            return try json(highlights)
        case "cmux.changelog.surface.size":
            guard let height = params["height"]?.doubleValue else { throw PageError.invalidParams("height is required") }
            services.updater.log.append("update surface \(kind.rawValue): height \(Int(height))")
            let number = { (key: String) in CGFloat(params[key]?.doubleValue ?? 0) }
            onSize?(CGFloat(height), number("width"), number("overlay"), number("preview"))
            return .null
        case "cmux.changelog.surface.openChangelog":
            let focus = ChangelogFocus(area: params["area"]?.stringValue, entry: params["title"]?.stringValue)
            _ = !kind.showsLastUpdate ? services.updater.openStagedChangelog(focus: focus) : services.updater.openWhatsNewForLastUpdate(focus: focus)
            onAction?()
            return .null
        default: // Go back and the recent builds (UpdateRevertSurface)
            guard let answer = await UpdateRevertSurface(services.updater).call(op, params: params) else { throw PageError.unknownOp(op) }
            return answer
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        if stream == "cmux.changelog.surface.pointer" { return pointer.subscribe(onEvent: onEvent) }
        guard stream == "cmux.changelog.surface.changes" else { throw PageError.unknownOp(stream) }
        // task-owner: the page's subscription; cancelled with it.
        let task = Task { @MainActor [weak self] in
            for await (highlights, _) in ObservationStream({ [weak self] in (self?.highlights, self?.services?.updater.revertOffer) }) {
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
        let routes = [PageRoute(prefix: "cmux.changelog.surface.", provider: provider), PageRoute(prefix: provider.card.prefix, provider: provider.card), PageRoute(prefix: "cmux.changelog.", provider: notes), PageRoute(prefix: "cmux.app.", provider: native)]
        // The island floats over the window's backdrop: a Chromium page cannot be transparent.
        // Window chrome: a first click on See What's New acts while a Chromium page's window has the key.
        let page = PageWebView(descriptor: .changelog, routes: routes, route: "#/surface/\(kind.rawValue)", options: PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true, keepsLoadedWeb: true), overlayProcess: services.overlayProcess)
        native.anchor = { [weak page] in page }
        notes.anchor = { [weak page] in page }
        return page
    }
}
