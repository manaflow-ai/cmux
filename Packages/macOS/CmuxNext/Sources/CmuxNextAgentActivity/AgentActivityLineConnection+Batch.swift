public import CmuxNextCompat
public import Foundation

/// The drain type lives in CmuxNextCompat (CmuxNextAgentPane batches too); clients of the
/// connection keep naming it from here.
public typealias MainActorLineDrain<Value: Sendable> = CmuxNextCompat.MainActorLineDrain<Value>

extension AgentActivityLineConnection {
    /// Starts the connection and delivers its lines to the main actor in
    /// batches (``MainActorLineBatch``): `decode` runs on the connection's
    /// queue, `onDrain` on the main actor with at most one drain pending.
    /// Use this for every long-lived watch; never start a `Task` per line.
    public func start<Value: Sendable>(send: Data, limit: Int = 4096, decode: @escaping @Sendable (Data) -> Value?,
                                       onDrain: @escaping @MainActor @Sendable (MainActorLineDrain<Value>) -> Void) {
        let batch = MainActorLineBatch(limit: limit, drain: onDrain)
        start(send: send, onLine: { line in
            if let value = decode(line) { batch.submit(value) }
        }, onClose: { batch.close() })
    }
}
