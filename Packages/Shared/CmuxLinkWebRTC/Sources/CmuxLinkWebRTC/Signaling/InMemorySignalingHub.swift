import os

/// An in-process signaling relay for tests and previews: routes by `to`,
/// rewrites `from` to the sender's endpoint id like `HostDO`, and lets a
/// test rewrite or drop messages in flight (a hostile relay).
public final class InMemorySignalingHub: Sendable {
    public typealias Interceptor = @Sendable (SignalMessage) -> SignalMessage?

    private struct State {
        var endpoints: [String: AsyncStream<SignalMessage>.Continuation] = [:]
        var interceptor: Interceptor?
        var relayed = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// A channel for one install id. A second endpoint with the same id
    /// replaces the first (one socket per identity, b1-control-do.md 2).
    public func endpoint(id: String) -> any SignalingChannel {
        let (stream, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .unbounded)
        state.withLock { state in
            state.endpoints[id]?.finish()
            state.endpoints[id] = sink
        }
        return InMemorySignalingEndpoint(id: id, hub: self, incoming: stream)
    }

    /// Rewrites (or drops, by returning nil) every relayed message.
    public func setInterceptor(_ interceptor: Interceptor?) {
        state.withLock { $0.interceptor = interceptor }
    }

    /// How many messages the hub delivered.
    public var relayedCount: Int { state.withLock { $0.relayed } }

    func relay(_ message: SignalMessage, from sender: String) throws {
        var message = message
        message.from = sender
        let interceptor = state.withLock { $0.interceptor }
        if let interceptor {
            guard let rewritten = interceptor(message) else { return }
            message = rewritten
        }
        let to = message.to
        let target = state.withLock { state -> AsyncStream<SignalMessage>.Continuation? in
            guard let target = state.endpoints[to] else { return nil }
            state.relayed += 1
            return target
        }
        guard let target else { throw InMemorySignalingError.peerOffline(message.to) }
        target.yield(message)
    }
}
