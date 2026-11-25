public import Foundation
import CmuxNextCompat

/// One window's widgets of one place (the sidebar): the person's layout as the daemon keeps it,
/// one `cmux.widget/1` mount per placed tile, and the person's edits. The layout is read again on
/// `apps-widgets-changed` (an edit in any window or on any client), on a new connection and when
/// the installed apps change, so every window follows. Nothing mounts while no widget is placed:
/// listing reads the daemon's catalog and mirror only, and no app host starts for it.
@MainActor
public final class AppWidgetArea {
    /// One placed tile's mount; a resize mounts it again at its new size.
    public struct Mounted {
        public let tile: AppWidgetTile
        public let mount: AppMount
    }

    public let place: String
    let client: AppsClient
    /// What the daemon last answered, with the person's edits in flight applied.
    public private(set) var catalog = AppWidgetCatalog()
    /// The placed tiles' mounts, by instance.
    public private(set) var mounted: [String: Mounted] = [:]
    /// Edit mode: minus badges, resize, drag to arrange, Add Widget.
    public var isEditing = false {
        didSet { if isEditing != oldValue { onChange?() } }
    }
    /// Runs after the tiles, their sizes or edit mode changed (the host lays out again).
    public var onChange: (() -> Void)?
    /// Runs when the daemon refused an edit (the area shows the daemon's layout again).
    public var onEditRefused: ((String) -> Void)?
    /// Whether each mount was last reported shown (`apps.widgets.visible`), by mount id.
    private var reportedVisible: [String: Bool] = [:]
    private var reading: Task<Void, Never>?
    /// Mounts the tiles the client could not mount before its app list landed.
    private var listFeed: Task<Void, Never>?
    private var readAgain = false
    /// Edits sent and not yet answered: a read that answers meanwhile may predate them, so it is
    /// dropped and the area reads once more after the last one.
    private var pendingEdits = 0
    private var started = false
    /// The window's sidebar went away: nothing reads or mounts any more.
    private var released = false

    public init(client: AppsClient, place: String) {
        self.client = client
        self.place = place
    }

    /// The placed tiles, in the person's order.
    public var tiles: [AppWidgetTile] { catalog.tiles }
    public var hasTiles: Bool { !catalog.tiles.isEmpty }
    /// The area's section title.
    public var title: String { AppWidgetStrings.sectionTitle }

    /// Reads the layout and follows its changes. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        client.observeEvents(owner: self) { [weak self] event in self?.hear(event) }
        // task-owner: this area (cancelled by `releaseAll`); event-driven (Observation): a tile whose
        // app the client did not know yet mounts once the client's list lands.
        listFeed = Task { [weak self, client] in
            for await listed in ObservationStream({ client.isListed }) where listed {
                self?.syncMounts()
            }
        }
        read()
    }

    func hear(_ event: AppsTransportEvent) {
        switch event {
        case let .widgetsChanged(_, place):
            if place == nil || place == self.place { read() }
        case .availability(let availability):
            guard availability.isAvailable else { return }
            // The client mounted every tile again, and a new mount runs as shown: say again which are hidden.
            for entry in mounted.values where reportedVisible[entry.mount.id] == false { client.setWidgetVisible(entry.mount, false) }
            read()
        case .changed:
            // An app installed, removed, hidden or turned off: its widget comes or goes.
            read()
        default:
            break
        }
    }

    /// Reads the layout again; calls that arrive while a read runs make one more read after it.
    public func read() {
        guard !released else { return }
        guard reading == nil else {
            readAgain = true
            return
        }
        // task-owner: this area (one read at a time; cancelled by `releaseAll`).
        reading = Task { [weak self] in
            guard let self else { return }
            let answer: AppWidgetCatalog? = try? await client.widgets(place: place)
            guard !Task.isCancelled, !released else { return }
            reading = nil
            if let answer, pendingEdits == 0 { show(answer) }
            if readAgain, pendingEdits == 0 {
                readAgain = false
                read()
            }
        }
    }

    /// Shows `next` (a read, or an edit applied ahead of its commit): mounts new tiles, mounts a
    /// resized tile again at its size, unmounts tiles that left.
    func show(_ next: AppWidgetCatalog) {
        let before = catalog
        catalog = next
        let changed = syncMounts(notifying: false)
        if before != next || changed { onChange?() }
    }

    /// Gives each placed tile its mount at its size and ends the mounts of tiles that left.
    @discardableResult
    func syncMounts(notifying: Bool = true) -> Bool {
        guard !released else { return false }
        var changed = false
        let live = Set(catalog.tiles.map(\.instance))
        for (instance, entry) in mounted where !live.contains(instance) {
            unmount(instance, entry)
            changed = true
        }
        for tile in catalog.tiles {
            if let entry = mounted[tile.instance], entry.tile == tile { continue }
            if let entry = mounted[tile.instance] {
                unmount(tile.instance, entry)
                changed = true
            }
            guard let mount = client.mountWidget(tile.app, place: place, size: tile.size, instance: tile.instance) else { continue }
            mounted[tile.instance] = Mounted(tile: tile, mount: mount)
            // Hidden until a view shows it: a tile no window draws (a collapsed sidebar, a band not
            // built yet) gets no clock ticks.
            reportedVisible[mount.id] = false
            client.setWidgetVisible(mount, false)
            changed = true
        }
        if changed, notifying { onChange?() }
        return changed
    }

    private func unmount(_ instance: String, _ entry: Mounted) {
        mounted[instance] = nil
        reportedVisible[entry.mount.id] = nil
        client.unmount(entry.mount)
    }

    /// Applies the person's `edit` at once and sends it; a refusal reads the daemon's layout again.
    public func edit(_ edit: AppWidgetEdit) {
        var next = catalog
        next.tiles = edit.applied(to: next.tiles)
        show(next)
        pendingEdits += 1
        let place = place
        // task-owner: one edit's round trip; the area outlives it or ignores its answer (weak).
        Task { [weak self, client] in
            var refusal: String?
            do throws(AppsClientError) {
                try await client.editWidgets(place: place, edit)
            } catch {
                refusal = error.description
            }
            guard let self else { return }
            pendingEdits -= 1
            if let refusal { onEditRefused?(refusal) }
            // The daemon's layout after the last edit (a refusal puts its own back).
            if pendingEdits == 0 { read() }
        }
    }

    /// Reports which tiles show (the sidebar collapsed, the window covered, the section scrolled away
    /// or folded hide them). Only changes go out.
    public func setVisible(_ visible: Bool, instance: String) {
        guard let mount = mounted[instance]?.mount, reportedVisible[mount.id] != visible else { return }
        reportedVisible[mount.id] = visible
        client.setWidgetVisible(mount, visible)
    }

    /// Unmounts every tile and stops reading (the window's sidebar went away).
    public func releaseAll() {
        reading?.cancel()
        reading = nil
        listFeed?.cancel()
        listFeed = nil
        released = true
        for (instance, entry) in mounted { unmount(instance, entry) }
    }

    /// Mounts a gallery preview of `app`'s widget at `size` (`preview: true`: sample data, writes
    /// nothing). The caller unmounts it with ``endPreview(_:)``.
    public func preview(_ app: String, size: AppWidgetSize) -> AppMount? {
        client.mountWidget(app, place: place, size: size, instance: "preview-\(size.rawValue)", preview: true)
    }

    public func endPreview(_ mount: AppMount) { client.unmount(mount) }

    /// Where an app's files are (scene images).
    public func bundleDirectory(_ app: String) -> URL? { client.bundleDirectory(for: app) }
}
