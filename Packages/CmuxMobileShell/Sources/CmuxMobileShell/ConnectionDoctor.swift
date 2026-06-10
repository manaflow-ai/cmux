public import CMUXMobileCore
import Foundation
public import Observation

/// Runs the connection doctor's environment probes concurrently and publishes
/// the resulting decision-tree checklist for the UI.
///
/// One instance backs one doctor screen. Re-running (the Run Again button, or
/// the screen returning to the foreground) supersedes any in-flight run: only
/// the newest run's results publish, so overlapping triggers can never
/// interleave rows from different environment snapshots.
@MainActor
@Observable
public final class ConnectionDoctor {
    /// The latest completed checklist, or `nil` before the first run finishes.
    public private(set) var report: ConnectionDoctorReport?
    /// Whether a probe run is currently in flight.
    public private(set) var isRunning = false

    @ObservationIgnored private let probes: ConnectionDoctorProbes
    @ObservationIgnored private let analytics: any AnalyticsEmitting
    /// Identity of the newest run; older runs compare against it before
    /// publishing so a superseded run silently discards its results.
    @ObservationIgnored private var runGeneration = UUID()

    /// Creates a doctor over a probe set.
    /// - Parameters:
    ///   - probes: The environment probes to run.
    ///   - analytics: Product-analytics emitter for the per-run summary event.
    public init(
        probes: ConnectionDoctorProbes,
        analytics: any AnalyticsEmitting = NoopAnalytics()
    ) {
        self.probes = probes
        self.analytics = analytics
    }

    /// Runs every probe concurrently and publishes the resulting checklist.
    ///
    /// The snapshot resolves first (it names the routes to dial); the
    /// reachability, tailnet, registry, and per-route dial probes then run
    /// concurrently. Each probe is individually bounded, so the run resolves
    /// in a few seconds even when the Mac is asleep.
    /// - Parameter trigger: Why this run started (`appear`, `rerun`,
    ///   `foreground`), recorded on the analytics summary event.
    public func run(trigger: String) async {
        let generation = UUID()
        runGeneration = generation
        isRunning = true
        defer {
            if runGeneration == generation {
                isRunning = false
            }
        }

        let probes = probes
        let snapshot = await probes.connection()
        async let isOnline = probes.isOnline()
        async let tailscale = probes.tailscale()
        async let registry = probes.registry(snapshot.macDeviceID, snapshot.routes)
        let dials = await Self.dialConcurrently(routes: snapshot.routes, probes: probes)

        let results = ConnectionDoctorProbeResults(
            isOnline: await isOnline,
            tailscale: await tailscale,
            snapshot: snapshot,
            dials: dials,
            registry: await registry
        )
        guard runGeneration == generation, !Task.isCancelled else { return }
        let report = ConnectionDoctorReport.make(results: results)
        self.report = report
        analytics.capture("ios_connection_doctor_completed", [
            "trigger": .string(trigger),
            "first_failure": .string(report.primaryFailure?.id.rawValue ?? "none"),
        ])
    }

    /// Dials every host/port route concurrently, preserving the routes' input
    /// (priority) order in the returned outcomes.
    private static func dialConcurrently(
        routes: [CmxAttachRoute],
        probes: ConnectionDoctorProbes
    ) async -> [ConnectionDoctorProbeResults.RouteDial] {
        let dialable = routes.filter { route in
            if case .hostPort = route.endpoint {
                return true
            }
            return false
        }
        guard !dialable.isEmpty else { return [] }
        let outcomes = await withTaskGroup(
            of: (Int, ConnectionDoctorProbeResults.DialOutcome).self
        ) { group in
            for (index, route) in dialable.enumerated() {
                group.addTask { (index, await probes.dial(route)) }
            }
            var byIndex: [Int: ConnectionDoctorProbeResults.DialOutcome] = [:]
            for await (index, outcome) in group {
                byIndex[index] = outcome
            }
            return byIndex
        }
        return dialable.enumerated().map { index, route in
            ConnectionDoctorProbeResults.RouteDial(route: route, outcome: outcomes[index] ?? .failed)
        }
    }
}
