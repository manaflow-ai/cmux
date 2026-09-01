public import CMUXMobileCore
public import CmuxMobileRPC
import Foundation

/// Multiplexes one client's render-grid event stream by terminal surface.
///
/// A remote Mac can have many terminals open at once, but the RPC transport
/// carries every `terminal.render_grid` event on one topic. Keeping one
/// underlying listener and routing each decoded frame to only its target
/// surface avoids decoding the same event once per mounted terminal.
@MainActor
public final class HiveRemoteRenderGridRouter {
    /// An individually cancellable surface subscription.
    struct Subscription {
        let stream: AsyncStream<MobileTerminalRenderGridFrame>
        let cancel: @MainActor () -> Void
    }

    private struct Listener {
        let surfaceID: String
        let continuation: AsyncStream<MobileTerminalRenderGridFrame>.Continuation
        let onOverflow: () -> Void
    }

    private let client: MobileCoreRPCClient
    private var listeners: [UUID: Listener] = [:]
    private var sourceTask: Task<Void, Never>?
    private var sourceGeneration = 0

    /// Creates a router over one connected (or reconnecting) RPC client.
    /// - Parameter client: The client's shared event transport.
    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    /// Returns a stream containing only frames for `surfaceID`.
    ///
    /// The first listener starts one shared underlying RPC listener. When the
    /// transport stream ends, all listeners finish and their terminal sessions
    /// can request fresh streams as part of their normal recovery loop.
    /// - Parameter onOverflow: Called when the bounded stream drops a frame;
    ///   the owner must request a full replay because render-grid frames are
    ///   deltas and cannot be safely resumed from a gap.
    public func stream(
        for surfaceID: String,
        onOverflow: @escaping () -> Void = {}
    ) -> AsyncStream<MobileTerminalRenderGridFrame> {
        subscription(for: surfaceID, onOverflow: onOverflow).stream
    }

    /// Creates a surface stream with an explicit cancellation handle.
    ///
    /// The handle is required when an initial replay fails before the caller
    /// begins iterating the stream; dropping an ``AsyncStream`` value alone
    /// does not release the router's continuation.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface to route.
    ///   - onOverflow: Called when the bounded stream drops a frame.
    func subscription(
        for surfaceID: String,
        onOverflow: @escaping () -> Void = {}
    ) -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MobileTerminalRenderGridFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        listeners[id] = Listener(
            surfaceID: surfaceID,
            continuation: continuation,
            onOverflow: onOverflow
        )
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeListener(id: id)
            }
        }
        startSourceIfNeeded()
        return Subscription(
            stream: stream,
            cancel: { [weak self] in
                self?.removeListener(id: id)
            }
        )
    }

    /// Stop the shared listener and finish every surface stream.
    public func stop() {
        sourceGeneration &+= 1
        sourceTask?.cancel()
        sourceTask = nil
        finishListeners()
    }

    private func startSourceIfNeeded() {
        guard sourceTask == nil, !listeners.isEmpty else { return }
        sourceGeneration &+= 1
        let generation = sourceGeneration
        let client = self.client
        sourceTask = Task { [weak self] in
            let source = await client.subscribe(to: ["terminal.render_grid"])
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.events.subscribe",
                    params: ["topics": ["terminal.render_grid"]]
                )
                _ = try await client.sendRequest(request)
            } catch {
                self?.finishSource(generation: generation)
                return
            }
            for await envelope in source {
                guard !Task.isCancelled,
                      let payload = envelope.payloadJSON else { continue }
                let frame = await Task.detached(priority: .userInitiated) {
                    HiveRemoteRenderGridDecoder().decodeFrame(payload)
                }.value
                guard let frame, !Task.isCancelled else { continue }
                self?.yield(frame, generation: generation)
            }
            guard !Task.isCancelled else { return }
            self?.finishSource(generation: generation)
        }
    }

    private func yield(_ frame: MobileTerminalRenderGridFrame, generation: Int) {
        guard generation == sourceGeneration else { return }
        for listener in listeners.values where listener.surfaceID == frame.surfaceID {
            if case .dropped = listener.continuation.yield(frame) {
                listener.onOverflow()
            }
        }
    }

    private func finishSource(generation: Int) {
        guard generation == sourceGeneration else { return }
        sourceTask = nil
        finishListeners()
    }

    private func finishListeners() {
        let continuations = listeners.values.map(\.continuation)
        listeners.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeListener(id: UUID) {
        guard let listener = listeners.removeValue(forKey: id) else { return }
        listener.continuation.finish()
        if listeners.isEmpty {
            stop()
        }
    }
}
