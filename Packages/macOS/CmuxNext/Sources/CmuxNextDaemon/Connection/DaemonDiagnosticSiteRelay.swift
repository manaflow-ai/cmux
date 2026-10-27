public import CmuxNextCompat

/// Hands the daemon's `server-diagnostic-site` events to one sink, each item once by its `id`, holding the ones
/// that arrive before the sink is installed (as the blocking detector replays its table at `install`).
///
/// Three relays carry them. Each transport's (``DaemonDiagnosticSite`` items) takes the sites its reader decodes,
/// which come during the handshake, and holds them until the handshake names the daemon life; then it hands
/// each on as a ``DaemonDiagnosticSite/Sighting`` to the connection's ``DaemonConnection/diagnosticSites``. That
/// one forwards (``forward(to:)``) to the `DaemonService`'s, where the app's hang reports install their sink
/// (`WatchdogReporting`). A daemon replays its sites to every new connection, so the connection's and the
/// service's once-per-sighting rule keeps a reconnect from reporting them again; across app launches the
/// sink's `DaemonSiteLedger` does.
///
/// ```swift
/// service.diagnosticSites.install { sighting in work.post(.bestEffort, mayBlock: .files) { sink.record(daemonSite: sighting) } }
/// ```
public final class DaemonDiagnosticSiteRelay<Item: Sendable & Identifiable>: Sendable where Item.ID: Sendable {
    /// Takes one item; it must not block (it may run on a connection's reader thread).
    public typealias Sink = @Sendable (Item) -> Void

    /// The most items held before a sink is installed, and remembered as seen: a daemon keeps at most 512 per
    /// life. Past it an item is still delivered (the sink keeps one per site) but no longer held or remembered.
    public static var capacity: Int { 1_024 }

    private struct State {
        var sink: Sink?
        var held: [Item] = []
        /// The `id`s delivered or held: a daemon may name a site's kind differently after a restart, and it is
        /// still the site.
        var seen: Set<Item.ID> = []
    }

    // Lock carve-out: taken once per site a daemon sends a connection (a few per daemon life) and once at
    // install; it guards three small values and no call runs under it.
    private let state = Mutex(State())

    /// Makes an empty relay with no sink.
    public init() {}

    /// Delivers `item` to the sink, or holds it until ``install(_:)``; an item delivered before does nothing.
    public func deliver(_ item: Item) {
        let sink: Sink? = state.withLock { state in
            if state.seen.contains(item.id) { return nil }
            if state.seen.count < Self.capacity { state.seen.insert(item.id) }
            if let sink = state.sink { return sink }
            if state.held.count < Self.capacity { state.held.append(item) }
            return nil
        }
        sink?(item)
    }

    /// Installs the one sink (replacing any earlier one) and hands it the items held so far, in order.
    public func install(_ sink: @escaping Sink) {
        let held: [Item] = state.withLock { state in
            state.sink = sink
            defer { state.held = [] }
            return state.held
        }
        held.forEach(sink)
    }

    /// Installs as the sink one that delivers into `next` (a connection's relay into its service's).
    public func forward(to next: DaemonDiagnosticSiteRelay<Item>) {
        install { next.deliver($0) }
    }
}
