internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import Metal

/// Serializes the host's bounded GPU copy work away from AppKit's main actor.
actor TerminalRenderMetalBlitter {
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let releaseHandler: @Sendable (TerminalRenderFrameRelease) -> Void
    private let dispositionHandler: TerminalRenderFrameDispositionHandler?
    private let metricEventHandler: TerminalRenderCompositorMetricEventHandler?
    private let presentedHandler: TerminalRenderFramePresentedHandler?
    private var currentEpoch: UInt64
    private var currentLayer: TerminalRenderMetalLayerHandle
    private var inFlight = false
    private var pendingFrame: TerminalRenderFrame?
    private var stopped = false
    private var metricsStorage = TerminalRenderCompositorMetrics()

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        initialEpoch: UInt64,
        initialLayer: TerminalRenderMetalLayerHandle,
        releaseHandler: @escaping @Sendable (TerminalRenderFrameRelease) -> Void,
        dispositionHandler: TerminalRenderFrameDispositionHandler?,
        metricEventHandler: TerminalRenderCompositorMetricEventHandler?,
        presentedHandler: TerminalRenderFramePresentedHandler?
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.currentEpoch = initialEpoch
        self.currentLayer = initialLayer
        self.releaseHandler = releaseHandler
        self.dispositionHandler = dispositionHandler
        self.metricEventHandler = metricEventHandler
        self.presentedHandler = presentedHandler
    }

    func register(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        guard !stopped, epoch >= currentEpoch else { return }
        transitionIfNeeded(epoch: epoch, layer: layer)
    }

    func enqueue(
        _ frame: TerminalRenderFrame,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) -> TerminalRenderCompositorEnqueueResult {
        guard !stopped else {
            metricsStorage.rejectedFrames &+= 1
            metricsStorage.metalUnavailableFrames &+= 1
            metricEventHandler?(.rejectedFrame)
            metricEventHandler?(.metalUnavailable)
            record(frame, result: .metalUnavailable)
            release(frame)
            return .metalUnavailable
        }
        guard epoch >= currentEpoch else {
            let result = TerminalRenderCompositorEnqueueResult.rejected(
                .presentationGenerationMismatch
            )
            record(frame, result: result)
            release(frame)
            metricsStorage.rejectedFrames &+= 1
            metricEventHandler?(.rejectedFrame)
            return result
        }
        transitionIfNeeded(epoch: epoch, layer: layer)
        if inFlight {
            if let pendingFrame {
                release(pendingFrame)
                metricsStorage.coalescedFrames &+= 1
                metricEventHandler?(.coalescedFrame)
            }
            pendingFrame = frame
            record(frame, result: .coalesced)
            return .coalesced
        }
        // A prior drawable miss may have left one pending frame while no blit
        // is in flight. Prefer this newer admitted frame and release the exact
        // lease for the superseded IOSurface before attempting submission.
        if let pendingFrame {
            release(pendingFrame)
            self.pendingFrame = nil
            metricsStorage.coalescedFrames &+= 1
            metricEventHandler?(.coalescedFrame)
        }
        return submit(frame)
    }

    func retry(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        guard !stopped, epoch >= currentEpoch else { return }
        transitionIfNeeded(epoch: epoch, layer: layer)
        drainPendingFrame()
    }

    func metrics() -> TerminalRenderCompositorMetrics {
        metricsStorage
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let pendingFrame {
            release(pendingFrame)
        }
        pendingFrame = nil
    }

    private func transitionIfNeeded(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        guard epoch > currentEpoch else { return }
        if let pendingFrame {
            release(pendingFrame)
        }
        pendingFrame = nil
        currentEpoch = epoch
        currentLayer = layer
    }

    private func submit(_ frame: TerminalRenderFrame) -> TerminalRenderCompositorEnqueueResult {
        guard let sourceTexture = makeTexture(frame: frame) else {
            metricsStorage.rejectedFrames &+= 1
            metricEventHandler?(.rejectedFrame)
            record(frame, result: .invalidSurface)
            release(frame)
            return .invalidSurface
        }
        guard let drawable = currentLayer.layer.nextDrawable() else {
            metricsStorage.drawableUnavailableEvents &+= 1
            metricEventHandler?(.drawableUnavailable)
            pendingFrame = frame
            record(frame, result: .drawableUnavailable)
            return .drawableUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            metricsStorage.rejectedFrames &+= 1
            metricsStorage.metalUnavailableFrames &+= 1
            metricEventHandler?(.rejectedFrame)
            metricEventHandler?(.metalUnavailable)
            record(frame, result: .metalUnavailable)
            release(frame)
            return .metalUnavailable
        }

        commandBuffer.label = TerminalRenderMetalTraceLabels.hostCommandBuffer
        blit.label = TerminalRenderMetalTraceLabels.hostBlitEncoder
        blit.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: Int(frame.metadata.width),
                height: Int(frame.metadata.height),
                depth: 1
            ),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        inFlight = true
        metricsStorage.submittedBlits &+= 1
        metricEventHandler?(.submittedBlit)
        record(frame, result: .submitted)
        let release = releaseHandler
        let releaseRecord = TerminalRenderFrameRelease(frame: frame)
        let presentedMetadata = frame.metadata
        let presentedEpoch = currentEpoch
        drawable.addPresentedHandler { [weak self] _ in
            Task {
                await self?.frameBecameVisible(
                    presentedMetadata,
                    submissionEpoch: presentedEpoch
                )
            }
        }
        commandBuffer.addCompletedHandler { [weak self, frame] _ in
            // Retain the imported IOSurface until Metal has stopped reading it,
            // then permit the remote worker to reuse exactly this pool slot.
            _ = frame
            release(releaseRecord)
            Task { [weak self] in
                await self?.completedBlit()
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return .submitted
    }

    private func completedBlit() {
        inFlight = false
        drainPendingFrame()
    }

    private func frameBecameVisible(
        _ metadata: TerminalRenderFrameMetadata,
        submissionEpoch: UInt64
    ) {
        guard !stopped, submissionEpoch == currentEpoch else { return }
        presentedHandler?(metadata)
    }

    private func drainPendingFrame() {
        guard !inFlight, let frame = pendingFrame else { return }
        pendingFrame = nil
        _ = submit(frame)
    }

    private func makeTexture(frame: TerminalRenderFrame) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.metalPixelFormat(frame.metadata.pixelFormat),
            width: Int(frame.metadata.width),
            height: Int(frame.metadata.height),
            mipmapped: false
        )
        descriptor.storageMode = .shared
        // Metal has no explicit blit usage bit. Empty usage avoids claiming
        // shader or render-target work that the host never performs.
        descriptor.usage = []
        return frame.surface.withIOSurface { surface in
            device.makeTexture(
                descriptor: descriptor,
                iosurface: surface,
                plane: 0
            )
        }
    }

    private func release(_ frame: TerminalRenderFrame) {
        releaseHandler(TerminalRenderFrameRelease(frame: frame))
    }

    private func record(
        _ frame: TerminalRenderFrame,
        result: TerminalRenderCompositorEnqueueResult
    ) {
        dispositionHandler?(frame, result)
    }

    private static func metalPixelFormat(
        _ format: TerminalRenderPixelFormat
    ) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm:
            .bgra8Unorm
        case .rgba16Float:
            .rgba16Float
        }
    }
}
