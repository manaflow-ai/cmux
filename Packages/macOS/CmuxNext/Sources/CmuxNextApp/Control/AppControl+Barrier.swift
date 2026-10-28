import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextWakeups
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextDesign
import CmuxNextOracle
import CmuxNextSignposts
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
        router.registerSyncBarrier { [weak daemon, work = mainWork] in
            // The CLI's barrier: its read of the connection is automation work.
            guard let connection = await work.apply(.automation, owner: "control.sync_barrier", { daemon?.connection }) else {
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
    /// signals: the daemon store's settle and connection waits, a sync round trip that reads the
    /// connection epoch before it, the motion clocks' idle waits, and one `CommitBoundary`. DEV and bench builds only.
    func registerOracleSettle(_ router: ControlRouter, services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        let daemon = services.daemon
        let windows: @MainActor @Sendable () -> [NSWindow] = { [weak services] in services?.windows.controllers.compactMap(\.window) ?? [] }
        let sources = OracleSettleSources(
            store: daemon.store,
            sync: { [weak daemon] in await Self.oracleSync(daemon) },
            motionIdle: { await Motion.waitAtRest(windows) },
            commit: { _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in CommitBoundary().after { _ in done.resume(returning: ()) } } },
            motion: { Motion.running(in: windows()) })
        router.register(OracleSettleControl(router: router, facets: services.makeOracleFacets(), sources: sources).methods)
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// One sync round trip for the oracle's settle: the connection and its epoch read in one main-actor turn
    /// before the round trip, so the mark's sequence and epoch belong to the same connection. Unavailable while
    /// the store is not connected (no connection yet, a drop, a restart) or the round trip fails.
    private static func oracleSync(_ daemon: DaemonService?) async -> OracleSyncAttempt {
        guard let daemon else { return .unavailable(epoch: 0) }
        let store = daemon.store
        let epoch = store.connectionEpoch
        guard case .connected = store.connectionState, let connection = daemon.connection else { return .unavailable(epoch: epoch) }
        do {
            _ = try await connection.request(IdentifyRequest())
        } catch {
            return .unavailable(epoch: epoch)
        }
        guard let sequence = await connection.eventSequence(), daemon.connection === connection else { return .unavailable(epoch: epoch) }
        return .reached(OracleDaemonMark(sequence: sequence, epoch: epoch))
    }
    #endif
}
