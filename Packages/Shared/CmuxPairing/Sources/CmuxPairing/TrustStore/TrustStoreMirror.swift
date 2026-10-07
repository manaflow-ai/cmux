public import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// Mirrors `trust:<user>` over the account's `/v1/wire/user` control socket
/// (b6-pairing.md sections 1 and 3). One owner per process: the registry, the
/// trusted-key lookup and the Mac's authorizer read the same mirror. Events
/// apply in order; one the mirror cannot apply triggers a fresh snapshot.
public actor TrustStoreMirror {
    public private(set) var state: TrustStoreState?
    private var sinks: [UUID: AsyncStream<TrustStoreState>.Continuation] = [:]
    private var runner: Task<Void, Never>?

    public init(state: TrustStoreState? = nil) { self.state = state }

    /// Follows `trust:<user>` on `client` until `stop()`.
    public func start(client: ControlPlaneClient, user: String) {
        runner?.cancel()
        let stream = "trust:\(user)"
        runner = Task {
            var updates = await client.subscribe(stream)
            while !Task.isCancelled {
                var resync = false
                for await update in updates {
                    if !self.apply(update) { resync = true; break }
                }
                guard resync, !Task.isCancelled else { return }
                await client.unsubscribe(stream)
                updates = await client.subscribe(stream)
            }
        }
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        for sink in sinks.values { sink.finish() }
        sinks = [:]
    }

    /// The current state (when known) and every change after it.
    public func updates() -> AsyncStream<TrustStoreState> {
        let (stream, sink) = AsyncStream.makeStream(of: TrustStoreState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        sinks[id] = sink
        if let state { sink.yield(state) }
        sink.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    /// Applies one stream update; false when an event could not be applied
    /// (the caller resubscribes for a snapshot).
    @discardableResult
    public func apply(_ update: StreamUpdate) -> Bool {
        switch update {
        case .snapshot(let snapshot):
            guard let next = try? TrustStoreState(snapshot: snapshot.state) else { return false }
            publish(next)
        case .event(let event):
            guard var next = state else { return false }
            do { try next.apply(event) } catch { return false }
            publish(next)
        }
        return true
    }

    private func publish(_ next: TrustStoreState) {
        state = next
        for sink in sinks.values { sink.yield(next) }
    }

    private func drop(_ id: UUID) { sinks[id] = nil }
}
