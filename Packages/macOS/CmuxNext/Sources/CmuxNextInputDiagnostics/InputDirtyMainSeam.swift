#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// The hooks' way into the ledger: a hooked method runs on any thread, and only main-thread calls
/// reach the main-actor ledger.
nonisolated struct InputDirtyMainSeam {
    let ledger: InputDirtyLedger

    /// Runs `send`, a hooked call's original; on the main thread the ledger records the call first.
    /// A call off the main thread only passes.
    func around(_ call: InputDirtyCall, _ receiver: AnyObject, records: Bool, _ send: () -> Void) {
        guard Thread.isMainThread else { return send() }
        MainActor.assumeIsolated { ledger.record(call, receiver, records: records, send) } // main-proof: Thread.isMainThread checked above
    }
}
#endif
