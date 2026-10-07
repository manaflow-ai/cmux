import Synchronization

/// Fans catalog event streams (`workspace.changed`, `agent.changed`, ...)
/// out to app subscriptions (ABI `subscribe`). The App posts when its
/// mirror changes; engines subscribe per `cmux.events.on` / `cmux.live`.
/// Delivery is synchronous on the poster's thread; engines hop to their
/// own executor.
public nonisolated final class AppEventHub: Sendable {
    public typealias Handler = @Sendable (AppJSON) -> Void

    private struct Entry {
        let stream: String
        let handler: Handler
    }

    private let state = Mutex<(next: UInt64, entries: [UInt64: Entry])>((1, [:]))

    public init() {}

    /// Registers `handler` for `stream`; returns a token for `unsubscribe`.
    public func subscribe(_ stream: String, handler: @escaping Handler) -> UInt64 {
        state.withLock { state in
            let token = state.next
            state.next += 1
            state.entries[token] = Entry(stream: stream, handler: handler)
            return token
        }
    }

    public func unsubscribe(_ token: UInt64) {
        _ = state.withLock { $0.entries.removeValue(forKey: token) }
    }

    /// Delivers `payload` to every subscriber of `stream`.
    public func post(_ stream: String, payload: AppJSON = .object([:])) {
        let handlers = state.withLock { $0.entries.values.filter { $0.stream == stream }.map(\.handler) }
        for handler in handlers { handler(payload) }
    }

    /// Streams with at least one subscriber (the App skips work for others).
    public var activeStreams: Set<String> { state.withLock { Set($0.entries.values.map(\.stream)) } }
}
