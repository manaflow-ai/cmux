#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// The hooks' way into the ledger: a hooked method runs on any thread, and only main-thread calls
/// reach the main-actor ledger. The receiver and the original stay on the hooked call's side: the
/// ledger gets a Sendable reading of the receiver, and the original runs between enter and leave.
nonisolated struct InputDirtyMainSeam {
    let ledger: InputDirtyLedger

    /// Runs `send`, a hooked call's original; on the main thread the ledger records the call first.
    /// A call off the main thread only passes.
    func around(_ call: InputDirtyCall, _ receiver: AnyObject, records: Bool, _ send: () -> Void) {
        guard Thread.isMainThread else { return send() }
        let notes = MainActor.assumeIsolated { ledger.enter(records: records) } // main-proof: Thread.isMainThread checked above
        defer { MainActor.assumeIsolated { ledger.leave() } } // main-proof: Thread.isMainThread checked above
        if notes {
            let dirtied = InputDirtyReceiver(receiver)
            MainActor.assumeIsolated { ledger.note(call, dirtied) } // main-proof: Thread.isMainThread checked above
        }
        send()
    }
}

/// What the ledger keeps of a hooked call's receiver, read on the hooked call's thread.
nonisolated struct InputDirtyReceiver: Sendable {
    /// The view the receiver draws for (``InputDirtyLedger/hostingView(of:)``).
    let view: NSView?
    let classID: ObjectIdentifier
    let className: String

    init(_ receiver: AnyObject) {
        view = InputDirtyLedger.hostingView(of: receiver)
        let receiverClass: AnyObject.Type = type(of: receiver)
        classID = ObjectIdentifier(receiverClass)
        className = String(describing: receiverClass)
    }
}
#endif
