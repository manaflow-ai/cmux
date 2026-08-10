import CmuxTerminalCore

/// Actor-isolated renderer-to-main-actor frame delivery.
///
/// The synchronous renderer ingress skips inactive demand, then yields into a
/// newest-value stream. One actor consumer rechecks demand before awaiting the
/// main-actor receiver, so a stalled UI retains at most one pending frame
/// without creating one task per frame.
actor RenderedFrameDeliveryCoordinator {
    nonisolated private let continuation: AsyncStream<Void>.Continuation
    nonisolated private let renderDemand: (any RenderDemandGating)?
    nonisolated private let localRenderDemand: (any RenderDemandGating)?
    nonisolated private let keyboardCopyModeCursorDemand: (any RenderDemandGating)?
    private let frames: AsyncStream<Void>
    private weak var receiver: (any TerminalRenderedFrameReceiving)?

    init(
        renderDemand: (any RenderDemandGating)? = nil,
        localRenderDemand: (any RenderDemandGating)? = nil,
        keyboardCopyModeCursorDemand: (any RenderDemandGating)? = nil,
        receiver: (any TerminalRenderedFrameReceiving)? = nil,
        startConsumer: Bool = true
    ) {
        let (frames, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.frames = frames
        self.continuation = continuation
        self.renderDemand = renderDemand
        self.localRenderDemand = localRenderDemand
        self.keyboardCopyModeCursorDemand = keyboardCopyModeCursorDemand
        self.receiver = receiver
        if startConsumer {
            Task { [weak self] in
                for await _ in frames {
                    await self?.deliverFrameIfDemanded()
                }
            }
        }
    }

    /// Queues the newest frame synchronously from the renderer thread.
    ///
    /// Returns `true` when the frame occupied the empty buffer and `false`
    /// when demand is inactive, it replaced an older pending frame, or the
    /// stream had stopped.
    @discardableResult
    nonisolated func requestFrame() -> Bool {
        guard !activeDeliveryReasons.isEmpty else { return false }
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Surface-scoped work requested by the currently active demand leases.
    nonisolated var activeDeliveryReasons: TerminalRenderedFrameDeliveryReasons {
        var reasons: TerminalRenderedFrameDeliveryReasons = []
        if renderDemand?.isActive == true
            || localRenderDemand?.isActive == true {
            reasons.insert(.notification)
        }
        if keyboardCopyModeCursorDemand?.isActive == true {
            reasons.insert(.keyboardCopyModeCursor)
        }
        return reasons
    }

    private func deliverFrameIfDemanded() async {
        let reasons = activeDeliveryReasons
        guard !reasons.isEmpty, let receiver else { return }
        await receiver.enqueueRenderedFrameUpdate(reasons: reasons)
    }

    deinit {
        continuation.finish()
    }
}
