public import CmuxTerminalRenderProtocol
public import CmuxTerminalRenderTransport
internal import Foundation
internal import Metal

/// Sendable frame-ingress boundary for a compositor view.
///
/// AppKit owns layer installation on the main actor. Frame receipt, metadata
/// admission, coalescing, and Metal submission use this handle directly and
/// never enter the main actor.
public final class TerminalRenderCompositorIngress: @unchecked Sendable {
    private struct State {
        var admission: TerminalRenderCompositorAdmission
        var epoch: UInt64
        var layer: TerminalRenderMetalLayerHandle
        var receivedFrames: UInt64 = 0
        var admittedFrames: UInt64 = 0
        var metadataRejectedFrames: UInt64 = 0
        var retired = false
    }

    private enum AdmissionDecision {
        case submit(epoch: UInt64, layer: TerminalRenderMetalLayerHandle)
        case reject(TerminalRenderFrameRejection)
    }

    private let lock = NSLock()
    private var state: State
    private let blitter: TerminalRenderMetalBlitter
    private let frameReleaseHandler: @Sendable (TerminalRenderFrameRelease) -> Void
    private let frameDispositionHandler: TerminalRenderFrameDispositionHandler?
    private let metricEventHandler: TerminalRenderCompositorMetricEventHandler?

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        fence: TerminalRenderPresentationFence,
        initialLayer: TerminalRenderMetalLayerHandle,
        frameReleaseHandler: @escaping @Sendable (TerminalRenderFrameRelease) -> Void,
        frameDispositionHandler: TerminalRenderFrameDispositionHandler?,
        metricEventHandler: TerminalRenderCompositorMetricEventHandler?,
        framePresentedHandler: TerminalRenderFramePresentedHandler?
    ) {
        self.state = State(
            admission: TerminalRenderCompositorAdmission(fence: fence),
            epoch: 1,
            layer: initialLayer
        )
        self.frameReleaseHandler = frameReleaseHandler
        self.frameDispositionHandler = frameDispositionHandler
        self.metricEventHandler = metricEventHandler
        self.blitter = TerminalRenderMetalBlitter(
            device: device,
            commandQueue: commandQueue,
            initialEpoch: 1,
            initialLayer: initialLayer,
            releaseHandler: frameReleaseHandler,
            dispositionHandler: frameDispositionHandler,
            metricEventHandler: metricEventHandler,
            presentedHandler: framePresentedHandler
        )
    }

    /// Current exact presentation contract.
    public var fence: TerminalRenderPresentationFence {
        withState { $0.admission.fence }
    }

    /// Atomically replaces the visible generation before later frames arrive.
    func updateFence(
        _ fence: TerminalRenderPresentationFence,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        lock.lock()
        guard !state.retired, epoch > state.epoch else {
            lock.unlock()
            return
        }
        state.epoch = epoch
        state.layer = layer
        state.admission.reset(fence: fence)
        lock.unlock()

        let blitter = blitter
        Task {
            await blitter.register(epoch: epoch, layer: layer)
        }
    }

    /// Admits and submits one frame without touching AppKit's main actor.
    @discardableResult
    public func enqueue(
        _ frame: TerminalRenderFrame
    ) async -> TerminalRenderCompositorEnqueueResult {
        let decision = admissionDecision(for: frame)

        metricEventHandler?(.receivedFrame)
        switch decision {
        case .reject(let rejection):
            metricEventHandler?(.rejectedFrame)
            let result = TerminalRenderCompositorEnqueueResult.rejected(rejection)
            frameDispositionHandler?(frame, result)
            frameReleaseHandler(TerminalRenderFrameRelease(frame: frame))
            return result
        case .submit(let epoch, let layer):
            metricEventHandler?(.admittedFrame)
            return await blitter.enqueue(frame, epoch: epoch, layer: layer)
        }
    }

    private func admissionDecision(
        for frame: TerminalRenderFrame
    ) -> AdmissionDecision {
        lock.lock()
        defer { lock.unlock() }
        state.receivedFrames &+= 1
        if state.retired {
            state.metadataRejectedFrames &+= 1
            return .reject(.presentationGenerationMismatch)
        } else if let rejection = state.admission.accept(frame.metadata) {
            state.metadataRejectedFrames &+= 1
            return .reject(rejection)
        } else {
            state.admittedFrames &+= 1
            return .submit(epoch: state.epoch, layer: state.layer)
        }
    }

    /// Retries the newest deferred frame on the current layer generation.
    public func retry() async {
        let current: (UInt64, TerminalRenderMetalLayerHandle)? = withState { state in
            guard !state.retired else { return nil }
            return (state.epoch, state.layer)
        }
        guard let current else { return }
        await blitter.retry(epoch: current.0, layer: current.1)
    }

    /// Snapshot of bounded admission and off-main blit counters.
    public func metricsSnapshot() async -> TerminalRenderCompositorMetrics {
        let ingressMetrics: (UInt64, UInt64, UInt64) = withState {
            ($0.receivedFrames, $0.admittedFrames, $0.metadataRejectedFrames)
        }
        var result = await blitter.metrics()
        result.receivedFrames = ingressMetrics.0
        result.admittedFrames = ingressMetrics.1
        result.rejectedFrames &+= ingressMetrics.2
        return result
    }

    /// Synchronously fences all later frames, then releases pending GPU work.
    func retire(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        lock.lock()
        guard !state.retired else {
            lock.unlock()
            return
        }
        state.retired = true
        state.epoch = epoch
        state.layer = layer
        lock.unlock()

        let blitter = blitter
        Task {
            await blitter.stop()
        }
    }

    func stop() {
        lock.lock()
        state.retired = true
        lock.unlock()
        let blitter = blitter
        Task {
            await blitter.stop()
        }
    }

    private func withState<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }
}
