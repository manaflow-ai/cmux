import Foundation

/// The first of a person proof's events (``AgentPaneTransport/provePerson(socket:ids:)``): its
/// reply, a new key the daemon on its socket took from this launch, or the connection's close. No
/// clock: acpmux holds a proof until a key it answers lands (`hub/person.rs` `proves_when_keyed`),
/// so these events are the only ends of the wait.
enum AcpmuxProveRace {
    enum Outcome: Equatable, Sendable {
        /// The daemon answered: true when the connection is the person now. A close is false.
        case answered(Bool)
        /// A daemon on this socket took this key from this launch, not the one proved.
        case rekeyed(String)
    }

    /// - Parameters:
    ///   - proved: the key the proof is under.
    ///   - socketPath: watched for a key a daemon takes (``AcpmuxPersonKey/whenDelivered(socketPath:_:)``);
    ///     nil when the daemon takes no later proof (an older acpmux), so a new key changes nothing.
    ///   - send: sends the proof and calls its argument with the answer.
    ///   - closed: returns once the connection closed. Its wait outlives the race at most until then.
    @MainActor
    static func first(proved: String, socketPath: String?,
                      send: (@escaping @Sendable (Bool) -> Void) -> Void,
                      closed: @escaping @Sendable () async -> Void) async -> Outcome {
        // Only the first event decides; the ones after it are dropped.
        let (events, sink) = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // Watched before the check, so a key taken between them is heard.
        let watch = socketPath.map { path in
            AcpmuxPersonKey.whenDelivered(socketPath: path) { key in
                if key != proved { sink.yield(.rekeyed(key)) }
            }
        }
        defer {
            if let watch { AcpmuxPersonKey.stopWatching(watch) }
            sink.finish()
        }
        if let socketPath, let key = AcpmuxPersonKey.deliveredKey(for: socketPath), key != proved {
            return .rekeyed(key)
        }
        // task-owner: ends at the connection's close; its yield after the race is dropped
        Task { await closed(); sink.yield(.answered(false)) }
        send { sink.yield(.answered($0)) }
        for await event in events { return event }
        return .answered(false)
    }
}
