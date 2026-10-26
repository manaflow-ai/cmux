public import CmuxNextCompat

/// Hands the daemon's `server-diagnostic-site` events (``DaemonDiagnosticSite``) to one sink, each site once,
/// holding the ones that arrive before the sink is installed (as the blocking detector replays its table at
/// `install`). A connection that echoes `diagnostic-sites-v1` delivers into its own relay from its reader
/// thread; the `DaemonService` installs on it a sink that delivers into the service's relay, where the app's
/// hang reports install theirs (`WatchdogReporting`). A daemon replays its sites to each new connection, so
/// the once-per-site rule here is what keeps a reconnect from reporting them again.
///
/// ```swift
/// service.diagnosticSites.install { site in work.post(.bestEffort, mayBlock: .files) { sink.record(daemonSite: site) } }
/// ```
public final class DaemonDiagnosticSiteRelay: Sendable {
    /// Takes one site; it must not block (it may run on a connection's reader thread).
    public typealias Sink = @Sendable (DaemonDiagnosticSite) -> Void

    /// The most sites held before a sink is installed, and remembered as seen: a daemon keeps at most 512 per
    /// life. Past it a site is still delivered (the sink keeps one per site) but no longer held or remembered.
    public static let capacity = 1_024

    private struct State {
        var sink: Sink?
        var held: [DaemonDiagnosticSite] = []
        /// ``DaemonDiagnosticSite/key``s delivered or held: a daemon may name a site's kind differently
        /// after a restart, and it is still the site.
        var seen: Set<String> = []
    }

    // Lock carve-out: taken once per site the daemon sees for the first time (a few per daemon life) and once
    // at install; it guards three small values and no call runs under it.
    private let state = Mutex(State())

    /// Makes an empty relay with no sink.
    public init() {}

    /// Delivers `site` to the sink, or holds it until ``install(_:)``; a site delivered before does nothing.
    public func deliver(_ site: DaemonDiagnosticSite) {
        let sink: Sink? = state.withLock { state in
            if state.seen.contains(site.key) { return nil }
            if state.seen.count < Self.capacity { state.seen.insert(site.key) }
            if let sink = state.sink { return sink }
            if state.held.count < Self.capacity { state.held.append(site) }
            return nil
        }
        sink?(site)
    }

    /// Installs the one sink (replacing any earlier one) and hands it the sites held so far, in order.
    public func install(_ sink: @escaping Sink) {
        let held: [DaemonDiagnosticSite] = state.withLock { state in
            state.sink = sink
            defer { state.held = [] }
            return state.held
        }
        held.forEach(sink)
    }
}
