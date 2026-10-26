import AppKit
import CmuxNextControl
import CmuxNextDaemon
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextDesign
import CmuxNextOracle
import CmuxNextSignposts
import CmuxNextWakeups
#endif

extension AppControl {
    /// `after: "sync"` (plans/cmux-next/state-ownership.md 4.3): one round
    /// trip to the local daemon, then the event sequence routed before its
    /// reply. The daemon replies to a mutation only after committing it and
    /// emits its events before later replies on this connection, so the
    /// snapshot that reflects this sequence includes every write another
    /// client (the CLI talking to the daemon) finished before the request.
    func registerSyncBarrier(_ router: ControlRouter, daemon: DaemonService) {
        let offline = MiscHandlerStrings.daemonOffline
        router.registerSyncBarrier { [weak daemon] in
            guard let connection = await MainActor.run(body: { daemon?.connection }) else {
                throw ControlError(code: "unavailable", message: offline)
            }
            _ = try await connection.request(IdentifyRequest())
            guard let sequence = await connection.eventSequence() else {
                throw ControlError(code: "unavailable", message: offline)
            }
            return sequence
        }
    }

    /// `debug.oracle.settle` and `debug.oracle.wait_for` (p15-oracle.md section 3B) over the app's own
    /// signals: the daemon store's settle (p15-oracle-029), the window motion clocks checked once per frame
    /// on the app's frame scheduler, and one `CommitBoundary`. DEV and bench builds only.
    func registerOracleSettle(_ router: ControlRouter, services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        let store = services.daemon.store
        let windows: @MainActor @Sendable () -> [NSWindow] = { [weak services] in services?.windows.controllers.compactMap(\.window) ?? [] }
        let sources = OracleSettleSources(
            // The epoch now: a sequence from an earlier reply has no epoch of its own.
            daemon: { [weak store] sequence in
                guard let store else { return [] }
                return await store.settle(through: sequence, since: store.connectionEpoch).map(\.rawValue)
            },
            motionIdle: { deadline in await Self.motionIdle(windows, until: deadline) },
            commit: { await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in CommitBoundary().after { _ in done.resume() } } },
            pending: { [weak store] in
                // The case name only: an intent's payload can hold a tab or workspace name.
                let intents = store?.pendingIntents.map { "intent:\(Mirror(reflecting: $0).children.first?.label ?? "unknown")" } ?? []
                return intents + Self.runningMotion(windows()).map { "motion:\($0)" }
            })
        router.register(OracleSettleControl(router: router, facets: services.makeOracleFacets(), sources: sources).methods)
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private static func runningMotion(_ windows: [NSWindow]) -> [String] {
        windows.flatMap { MotionClock.forWindow($0).running }
    }

    /// True once no window's motion clock steps an animator, false at `deadline`: checked now, then on each
    /// frame of the app's scheduler (a settle-wait frame client; the clocks tick on the same display frames).
    private static func motionIdle(_ windows: @escaping @MainActor @Sendable () -> [NSWindow], until deadline: ContinuousClock.Instant) async -> Bool {
        if Self.runningMotion(windows()).isEmpty { return true }
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            FrameClient(owner: "Oracle.settle", isAnimation: false, on: .app) { _ in
                let idle = Self.runningMotion(windows()).isEmpty
                guard idle || ContinuousClock.now >= deadline else { return true }
                done.resume(returning: idle)
                return false
            }.activate()
        }
    }
    #endif
}
