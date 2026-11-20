public import AppKit
public import Observation

/// The extension status items (`cmux.status/1`) cmux shows now, each mounted once: the daemon lists
/// them (`apps.status.list`, only installed, enabled and visible apps), and every titlebar and the
/// menu bar item's menu draw a view of the same mount. Nothing shows unless an app contributes one.
///
/// It lists again on every `apps-changed` (an install, a hide, a saved local manifest) and after a
/// reconnect, so a save moves or retitles an item with no relaunch; the scene itself updates live
/// through its mount. A mount lives while its app is listed.
@MainActor
@Observable
public final class AppStatusItems {
    /// One listed item and its mount.
    public struct Entry {
        public let item: AppStatusItem
        public let mount: AppMount
    }

    /// Every listed item, in the daemon's order (app id).
    public private(set) var entries: [Entry] = []
    @ObservationIgnored private let client: AppsClient
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(client: AppsClient) {
        self.client = client
    }

    /// The items drawn at `place`.
    public func entries(at place: AppStatusItem.Place) -> [Entry] { entries.filter { $0.item.place == place } }

    /// Starts following the daemon's list (idempotent).
    public func start() {
        guard !started else { return }
        started = true
        client.observeEvents(owner: self) { [weak self] event in
            switch event {
            case .changed, .availability: self?.refresh()
            default: break
            }
        }
        refresh()
    }

    /// Lists again; the reply replaces the entries (a newer request wins).
    public func refresh() {
        listing?.cancel()
        guard client.isAvailable else { return }
        // task-owner: one apps.status.list read; the next refresh cancels it
        listing = Task { [weak self, client] in
            let items: [AppStatusItem]
            do throws(AppsTransportError) { items = try await client.transport.statusItems() } catch { return }
            guard !Task.isCancelled else { return }
            self?.apply(items)
        }
    }

    func apply(_ items: [AppStatusItem]) {
        var kept: [String: AppMount] = [:]
        for entry in entries { kept[entry.item.app] = entry.mount }
        var next: [Entry] = []
        for item in items {
            if let mount = kept.removeValue(forKey: item.app) {
                next.append(Entry(item: item, mount: mount))
            } else {
                // The daemon listed it, so the app implements the interface; the mount names only that
                // (the client's own app list may land after this one).
                let implementation = client.app(item.app)?.manifest.sceneImplementation(interface: AppImplementation.status)
                    ?? AppImplementation(interface: AppImplementation.status, symbol: item.symbol)
                next.append(Entry(item: item, mount: client.mount(item.app, implementation: implementation, surface: Self.surface)))
            }
        }
        for mount in kept.values { client.unmount(mount) }
        let changed = next.map(\.item) != entries.map(\.item) || next.map(\.mount.id) != entries.map(\.mount.id)
        entries = next
        guard changed else { return }
        listeners.removeAll { $0.owner == nil }
        for listener in listeners { listener.run() }
    }

    /// A change listener held only while its owner lives.
    @MainActor private final class Listener {
        weak var owner: AnyObject?
        let run: @MainActor () -> Void
        init(owner: AnyObject, run: @escaping @MainActor () -> Void) {
            self.owner = owner
            self.run = run
        }
    }

    @ObservationIgnored private var listeners: [Listener] = []

    /// Runs `listener` after each change of the entries, while `owner` lives (a titlebar strip).
    public func observe(owner: AnyObject, _ listener: @escaping @MainActor () -> Void) {
        listeners.append(Listener(owner: owner, run: listener))
    }

    /// The menu bar item's menu rows (place `menuBar`): a fresh view of each item's drawn scene, made as
    /// the menu opens. An item whose scene has not drawn yet is left out.
    public func menuBarRows() -> [NSView] {
        entries(at: .menuBar).map { entry -> NSView in
            let scene = entry.mount.makeView()
            scene.setAccessibilityLabel(entry.item.title)
            return AppStatusMenuRow(scene: scene)
        }.filter { $0.frame.height > 0 }
    }

    /// The titlebar strip that draws the items placed there (`AppStatusStripView`).
    public func titlebarStrip(onWidthChange: (() -> Void)? = nil) -> AppStatusStripView {
        AppStatusStripView(items: self, onWidthChange: onWidthChange)
    }

    /// The mount's `surface` in its context.
    public static let surface = "statusItem"
}
