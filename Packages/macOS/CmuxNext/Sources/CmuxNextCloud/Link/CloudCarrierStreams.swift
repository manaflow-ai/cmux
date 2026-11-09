public import CmuxNextDaemon
public import Foundation
import CmuxNextCompat

/// The signed-in account's desktop carrier dials (``CloudCarrierDial/Connector`` built with these): each
/// dial child still dialing and each open stream is held here until it closes, so a sign-out, an account
/// or team switch, and Cloud turned off by policy end them all at once (``endAll()``), which the desktop
/// pane reads as a remote close. Each end is also a fence: an open whose connector was made before it,
/// waiting for its token, dialing, or started later, fails as closed instead of giving a live stream.
public nonisolated final class CloudCarrierStreams: Sendable {
    private struct State {
        var generation = 0
        var nextID = 0
        var stops: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// The generation a connector made now belongs to; ``endAll()`` moves past it.
    public var generation: Int { state.withLock { $0.generation } }

    /// How many dials and streams are held now.
    var count: Int { state.withLock { $0.stops.count } }

    /// Fences every open of the generation so far at once, then ends each held child and stream off the
    /// caller's thread (a stream's close reaps its child). The task finishes when all have ended.
    @discardableResult
    public func endAll() -> Task<Void, Never> {
        let stops: [@Sendable () -> Void] = state.withLock { state in
            state.generation += 1
            defer { state.stops = [:] }
            return Array(state.stops.values)
        }
        // task-owner: one pass over the stops taken above; each is a kill or an idempotent close.
        return Task.detached(priority: .userInitiated) {
            for stop in stops { stop() }
        }
    }

    /// Holds `stop` for an open of `generation` until ``release(_:)``; nil, with `stop` run at once,
    /// when an end came after that generation.
    func hold(generation: Int, stop: @escaping @Sendable () -> Void) -> Int? {
        let id: Int? = state.withLock { state in
            guard state.generation == generation else { return nil }
            state.nextID += 1
            state.stops[state.nextID] = stop
            return state.nextID
        }
        if id == nil { stop() }
        return id
    }

    /// The held open `id` has a new stop (its dial child became an open stream); false, with `stop`
    /// run at once, when an end took it first.
    func replace(_ id: Int, stop: @escaping @Sendable () -> Void) -> Bool {
        let held = state.withLock { state in
            guard state.stops[id] != nil else { return false }
            state.stops[id] = stop
            return true
        }
        if !held { stop() }
        return held
    }

    func release(_ id: Int) {
        state.withLock { _ = $0.stops.removeValue(forKey: id) }
    }
}

/// One desktop stream of ``CloudCarrierDial/Connector/open()``: the bridge's reads and sends, and a close
/// that ends its child and leaves ``CloudCarrierStreams``.
public nonisolated final class CloudCarrierStream: Sendable {
    private let stream: DaemonBridgeStream
    private let release: @Sendable () -> Void

    init(stream: DaemonBridgeStream, release: @escaping @Sendable () -> Void = {}) {
        (self.stream, self.release) = (stream, release)
    }

    /// The next bytes from the machine, in order; nil once the stream ended (a remote close, or ``CloudCarrierStreams/endAll()``).
    public func read() async -> Data? { await stream.read() }

    /// Writes `data`; throws once the stream closed.
    public func send(_ data: Data) async throws { try await stream.send(data) }

    /// Ends the stream and its child. Idempotent.
    public func close() {
        stream.close()
        release()
    }

    deinit { close() }
}
