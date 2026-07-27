import CmuxTerminalCore

/// Actor-isolated renderer-to-main-actor frame delivery.
///
/// The synchronous renderer ingress yields into a newest-value stream. One
/// actor consumer checks current demand before awaiting the main-actor
/// receiver, so a stalled UI retains at most one pending frame without
/// creating one task per frame.
actor RenderedFrameDeliveryCoordinator {
    nonisolated private let continuation: AsyncStream<Void>.Continuation
    private let frames: AsyncStream<Void>
    private weak var receiver: (any TerminalRenderedFrameReceiving)?
    private var renderDemand: (any RenderDemandGating)?
    private var localRenderDemand: (any RenderDemandGating)?

    init(startConsumer: Bool = true) {
        let (frames, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.frames = frames
        self.continuation = continuation
        if startConsumer {
            Task { [weak self] in
                for await _ in frames {
                    await self?.deliverFrameIfDemanded()
                }
            }
        }
    }

    /// Replaces the collaborators consulted for subsequent frame deliveries.
    func configure(
        renderDemand: (any RenderDemandGating)?,
        localRenderDemand: (any RenderDemandGating)?,
        receiver: (any TerminalRenderedFrameReceiving)?
    ) {
        self.renderDemand = renderDemand
        self.localRenderDemand = localRenderDemand
        self.receiver = receiver
    }

    /// Queues the newest frame synchronously from the renderer thread.
    ///
    /// Returns `true` when the frame occupied the empty buffer and `false`
    /// when it replaced an older pending frame or the stream had stopped.
    @discardableResult
    nonisolated func requestFrame() -> Bool {
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private func deliverFrameIfDemanded() async {
        guard GhosttyMetalLayer.hasActiveRenderDemand(
            global: renderDemand,
            local: localRenderDemand
        ), let receiver else { return }
        await receiver.enqueueRenderedFrameUpdate()
    }

    deinit {
        continuation.finish()
    }
}
