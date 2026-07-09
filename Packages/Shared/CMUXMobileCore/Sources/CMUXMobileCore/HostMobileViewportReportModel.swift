import Foundation
import Observation

/// Owns the shared mobile-terminal viewport state machine: per-surface,
/// per-client reported grids and the TTL cleanup that expires the non-sticky
/// (input-piggyback) ones.
///
/// This is the iOS/macOS half of the tmux-style shared resize. Each attached
/// device reports the grid it can show for a surface; the smallest attached
/// viewport wins, and every device pins + letterboxes its own render to the same
/// cols x rows while the Mac draws a border around the live area. The model keeps
/// the per-surface report map, recomputes the running minimum on every change, and
/// caps (or releases) the surface through ``MobileViewportSurfaceLimiting``.
///
/// Sticky reports come from the dedicated `mobile.terminal.viewport` RPC and live
/// for the client's connection lifetime (cleared on disconnect or surface
/// detach). Non-sticky reports piggyback on `terminal.input` and expire on
/// ``reportTTL`` so a client that only ever typed once does not pin the grid
/// forever.
///
/// ## Isolation and cleanup design
///
/// The model is `@MainActor`: every mutator (the apply / clear / prune entry
/// points) is already driven from the main actor by the v2 control socket and the
/// mobile data-plane RPC, so co-locating the state with its callers makes the
/// surface-limit calls plain in-isolation calls. There is no off-main writer, so
/// no lock or actor is needed.
///
/// The TTL cleanup replaces the legacy per-surface `DispatchSourceTimer` (banned:
/// not cancellable/testable, `DispatchSource` exposed on a god class) with a
/// per-surface cancellable `Task` that sleeps on an injected ``Clock`` and then
/// prunes. Staleness is absorbed by a per-surface generation guard rather than a
/// `Task.isCancelled` check: rescheduling bumps the generation, and a fired task
/// whose generation no longer matches is a no-op, which also covers the
/// schedule-then-immediately-reschedule race the old timer's `cancel()` handled.
@MainActor
@Observable
public final class HostMobileViewportReportModel {
    /// A single attached device's reported terminal grid for one surface.
    struct Report: Sendable, Equatable {
        var columns: Int
        var rows: Int
        var updatedAt: Date
        /// Sticky reports (from `mobile.terminal.viewport`) live for the
        /// connection lifetime; non-sticky reports (piggybacked on
        /// `terminal.input`) expire on the TTL.
        var sticky: Bool = false
    }

    /// How long a non-sticky report survives without a refresh before the TTL
    /// cleanup drops it. Faithful to the legacy `mobileViewportReportTTL`.
    /// `nonisolated` so it can seed the `init` default argument from any context.
    nonisolated public static let reportTTL: TimeInterval = 5

    /// Per-surface, per-client reported grids. Keyed by terminal surface id, then
    /// by client id.
    private(set) var reportsBySurfaceID: [UUID: [String: Report]] = [:]

    /// Per-surface generation counter; bumped on every (re)schedule so a stale
    /// cleanup task that fires after a newer schedule is a no-op.
    private var cleanupGenerationBySurfaceID: [UUID: UInt64] = [:]

    /// Per-surface in-flight cleanup task, cancelled when superseded or cleared.
    private var cleanupTasksBySurfaceID: [UUID: Task<Void, Never>] = [:]

    private let limiter: any MobileViewportSurfaceLimiting
    private let clock: any Clock<Duration>
    private let now: @MainActor () -> Date
    private let ttl: TimeInterval

    /// - Parameters:
    ///   - limiter: The seam that caps / releases the live surface render grid.
    ///   - clock: The clock the TTL cleanup sleeps on (inject a test clock to
    ///     drive expiry deterministically).
    ///   - ttl: The non-sticky report lifetime; defaults to ``reportTTL``.
    ///   - now: A `Date` provider, injectable for deterministic tests.
    public init(
        limiter: any MobileViewportSurfaceLimiting,
        clock: any Clock<Duration> = ContinuousClock(),
        ttl: TimeInterval = HostMobileViewportReportModel.reportTTL,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.limiter = limiter
        self.clock = clock
        self.ttl = ttl
        self.now = now
    }

    /// Record `clientID`'s reported grid for `surfaceID`, clamp it to the
    /// supported range, drop expired non-sticky peers, recompute the shared
    /// minimum, and cap the surface to it.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface the report applies to.
    ///   - clientID: The reporting device's client id.
    ///   - columns: The raw reported column count (clamped 20...300).
    ///   - rows: The raw reported row count (clamped 5...120).
    ///   - sticky: `true` for the dedicated viewport RPC, `false` for the
    ///     input-piggyback path.
    public func apply(surfaceID: UUID, clientID: String, columns rawColumns: Int, rows rawRows: Int, sticky: Bool) {
        let columns = min(max(rawColumns, 20), 300)
        let rows = min(max(rawRows, 5), 120)
        let timestamp = now()
        var reports = reportsBySurfaceID[surfaceID] ?? [:]
        reports = reports.filter { _, report in
            report.sticky || timestamp.timeIntervalSince(report.updatedAt) <= ttl
        }
        reports[clientID] = Report(columns: columns, rows: rows, updatedAt: timestamp, sticky: sticky)
        reportsBySurfaceID[surfaceID] = reports
        scheduleCleanup(surfaceID: surfaceID, reports: reports)

        guard let minColumns = reports.values.map(\.columns).min(),
              let minRows = reports.values.map(\.rows).min() else {
            return
        }
        limiter.applyMobileViewportLimit(
            surfaceID: surfaceID,
            columns: minColumns,
            rows: minRows,
            reason: "mobile.terminal.input"
        )
    }

    /// Remove a single client's report for a surface, then recompute the
    /// remaining minimum and re-apply or clear the surface's viewport limit so
    /// the macOS border reflects only the devices still attached.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface the client was reporting on.
    ///   - clientID: The client to drop.
    ///   - reason: The debug/telemetry reason forwarded to the surface.
    public func clear(surfaceID: UUID, clientID: String, reason: String) {
        guard var reports = reportsBySurfaceID[surfaceID],
              reports.removeValue(forKey: clientID) != nil else {
            return
        }
        if reports.isEmpty {
            reportsBySurfaceID[surfaceID] = nil
            cancelCleanup(surfaceID: surfaceID)
            limiter.clearMobileViewportLimit(surfaceID: surfaceID, reason: reason)
            return
        }
        reportsBySurfaceID[surfaceID] = reports
        scheduleCleanup(surfaceID: surfaceID, reports: reports)
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            limiter.applyMobileViewportLimit(
                surfaceID: surfaceID,
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
    }

    /// Drop every report owned by the given client ids across all surfaces.
    /// Called when a mobile connection closes so a disconnected device stops
    /// pinning the grid even though it never sent an explicit clear. Sticky
    /// reports rely on this signal instead of the TTL.
    ///
    /// - Parameters:
    ///   - clientIDs: The client ids to drop everywhere.
    ///   - reason: The debug/telemetry reason forwarded to each surface.
    public func clear(clientIDs: Set<String>, reason: String) {
        guard !clientIDs.isEmpty else { return }
        for surfaceID in Array(reportsBySurfaceID.keys) {
            for clientID in clientIDs {
                clear(surfaceID: surfaceID, clientID: clientID, reason: reason)
            }
        }
    }

    /// Drop all reports across all surfaces and clear each surface's viewport
    /// limit. Called when the mobile host stops.
    ///
    /// - Parameter reason: The debug/telemetry reason forwarded to each surface.
    public func clearAll(reason: String) {
        guard !reportsBySurfaceID.isEmpty || !cleanupTasksBySurfaceID.isEmpty else {
            return
        }
        for task in cleanupTasksBySurfaceID.values {
            task.cancel()
        }
        let surfaceIDs = Array(reportsBySurfaceID.keys)
        reportsBySurfaceID.removeAll()
        cleanupTasksBySurfaceID.removeAll()
        cleanupGenerationBySurfaceID.removeAll()
        for surfaceID in surfaceIDs {
            limiter.clearMobileViewportLimit(surfaceID: surfaceID, reason: reason)
        }
    }

    /// Expire any non-sticky reports for a surface whose TTL has elapsed, then
    /// re-apply or clear the surface limit and reschedule for the next expiry.
    /// The TTL cleanup task drives this; it is also safe to call directly.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface to prune.
    ///   - reason: The debug/telemetry reason forwarded to the surface.
    public func prune(surfaceID: UUID, reason: String) {
        let timestamp = now()
        guard var reports = reportsBySurfaceID[surfaceID] else {
            cancelCleanup(surfaceID: surfaceID)
            return
        }
        reports = reports.filter { _, report in
            report.sticky || timestamp.timeIntervalSince(report.updatedAt) <= ttl
        }
        guard !reports.isEmpty else {
            reportsBySurfaceID[surfaceID] = nil
            cancelCleanup(surfaceID: surfaceID)
            limiter.clearMobileViewportLimit(surfaceID: surfaceID, reason: reason)
            return
        }
        reportsBySurfaceID[surfaceID] = reports
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            limiter.applyMobileViewportLimit(
                surfaceID: surfaceID,
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
        scheduleCleanup(surfaceID: surfaceID, reports: reports)
    }

    private func scheduleCleanup(surfaceID: UUID, reports: [String: Report]) {
        cleanupTasksBySurfaceID[surfaceID]?.cancel()
        // Sticky reports live for the connection lifetime, so they never drive a
        // TTL timer; only non-sticky (input-piggyback) reports expire.
        guard let nextExpiry = reports.values
            .filter({ !$0.sticky })
            .map({ $0.updatedAt.addingTimeInterval(ttl) })
            .min() else {
            cancelCleanup(surfaceID: surfaceID)
            return
        }

        let generation = (cleanupGenerationBySurfaceID[surfaceID] ?? 0) &+ 1
        cleanupGenerationBySurfaceID[surfaceID] = generation
        // Match the legacy DispatchSourceTimer's +1s slack + 1ms floor so a
        // report is only pruned strictly after its TTL has elapsed.
        let secondsUntilExpiry = max(0.001, nextExpiry.timeIntervalSinceNow + 1)
        let duration = Duration.milliseconds(Int(secondsUntilExpiry * 1000))
        let clock = clock
        cleanupTasksBySurfaceID[surfaceID] = Task { [weak self] in
            try? await clock.sleep(for: duration, tolerance: nil)
            guard let self else { return }
            // Generation guard: a fire that lost a reschedule race is a no-op.
            // `Clock.sleep` already throws (and returns above) on cancellation.
            guard self.cleanupGenerationBySurfaceID[surfaceID] == generation else { return }
            self.prune(surfaceID: surfaceID, reason: "mobile.viewport.reportsExpired")
        }
    }

    private func cancelCleanup(surfaceID: UUID) {
        cleanupTasksBySurfaceID[surfaceID]?.cancel()
        cleanupTasksBySurfaceID[surfaceID] = nil
        cleanupGenerationBySurfaceID[surfaceID] = nil
    }

    #if DEBUG
    /// Test-only: clear all reports for a deterministic starting state.
    public func debugResetForTesting() {
        clearAll(reason: "mobile.viewport.testReset")
    }

    /// Test-only: seed a single report without driving the surface limiter.
    public func debugSetReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        var reports = reportsBySurfaceID[surfaceID] ?? [:]
        reports[clientID] = Report(columns: columns, rows: rows, updatedAt: updatedAt)
        reportsBySurfaceID[surfaceID] = reports
    }

    /// Test-only: the set of client ids currently reporting on a surface.
    public func debugReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        guard let reports = reportsBySurfaceID[surfaceID] else { return nil }
        return Set(reports.keys)
    }
    #endif
}
