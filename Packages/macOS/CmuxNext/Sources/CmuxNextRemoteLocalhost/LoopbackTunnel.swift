public import Foundation

/// What a tunnel to the machine's loopback delivers, in order.
public enum LoopbackTunnelEvent: Sendable, Equatable {
    case data(Data)
    /// The target ended its side.
    case eof
    /// Over; `error` describes an early end (connection lost, reset).
    case closed(error: String?)
}

/// One byte stream to a loopback port of a machine. The App adapts the
/// daemon client's `LoopbackStream` to it, so this module never imports
/// the daemon module.
public protocol LoopbackTunnel: Sendable {
    var events: AsyncStream<LoopbackTunnelEvent> { get }
    /// Waits while the machine's window is spent.
    func write(_ data: Data) async throws
    /// Received bytes were written on (returns flow-control credit).
    func consumed(_ count: Int)
    func shutdownWrite()
    func close()
}

/// One tunnel's bytes for a client that reads on demand (Open Desktop's native viewer). A pump
/// drains the tunnel's events as they come, so a burst bigger than the tunnel's own event buffer
/// (a full-screen update while the client decodes) never cancels the connection; reads take the
/// bytes in order. Past `limit` buffered bytes the tunnel closes. One reader per tunnel.
public actor LoopbackTunnelReader {
    private let tunnel: any LoopbackTunnel
    private let limit: Int
    private var pending: [Data] = []
    private var buffered = 0
    private var end: LoopbackTunnelEvent?
    private var waiter: CheckedContinuation<Void, Never>?
    private var pump: Task<Void, Never>?

    public init(_ tunnel: any LoopbackTunnel, limit: Int = 64 << 20) {
        self.tunnel = tunnel
        self.limit = limit
    }

    deinit {
        pump?.cancel()
    }

    /// The next bytes; nil at the end of the stream. Throws when the tunnel ended early.
    public func read() async throws -> Data? {
        startPump()
        while pending.isEmpty, end == nil {
            await withCheckedContinuation { waiter = $0 }
        }
        if !pending.isEmpty {
            let data = pending.removeFirst()
            buffered -= data.count
            return data
        }
        if case .closed(let error?)? = end { throw LoopbackTunnelFailure.other(error) }
        return nil
    }

    private func startPump() {
        guard pump == nil else { return }
        let events = tunnel.events
        // task-owner: ends with the tunnel's event stream, or when this reader goes.
        pump = Task { [weak self] in
            for await event in events {
                guard let self, await self.take(event) else { return }
            }
            await self?.take(.eof)
        }
    }

    /// False once the stream ended (or overflowed), which stops the pump.
    @discardableResult
    private func take(_ event: LoopbackTunnelEvent) -> Bool {
        guard end == nil else { return false }
        switch event {
        case .data(let data):
            tunnel.consumed(data.count)
            guard !data.isEmpty else { return true }
            pending.append(data)
            buffered += data.count
            if buffered > limit {
                end = .closed(error: "more than \(limit) bytes waiting")
                tunnel.close()
            }
        case .eof, .closed:
            end = event
        }
        let waiting = waiter
        waiter = nil
        waiting?.resume()
        return end == nil
    }
}
