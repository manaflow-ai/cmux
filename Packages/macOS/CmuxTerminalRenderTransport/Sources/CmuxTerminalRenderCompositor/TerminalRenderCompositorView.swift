public import AppKit
public import CmuxTerminalRenderProtocol
public import CmuxTerminalRenderTransport
internal import CoreGraphics
internal import Metal
internal import QuartzCore

/// Thin host view that performs one full IOSurface-to-drawable Metal blit.
///
/// Ghostty scene projection, glyph shaping, atlas updates, and terminal draw
/// passes belong to the authenticated renderer worker. This class deliberately
/// owns no terminal model, parser, font grid, glyph atlas, or render pipeline.
@MainActor
public final class TerminalRenderCompositorView: NSView {
    private let device: any MTLDevice
    private var metalLayer: CAMetalLayer
    private var metalLayerHandle: TerminalRenderMetalLayerHandle
    private let blitter: TerminalRenderMetalBlitter
    private let frameReleaseHandler: @Sendable (TerminalRenderFrameRelease) -> Void
    private var admission: TerminalRenderCompositorAdmission
    private var submissionEpoch: UInt64 = 1
    private var admittedFrames: UInt64 = 0
    private var metadataRejectedFrames: UInt64 = 0

    /// Current exact presentation contract.
    public var fence: TerminalRenderPresentationFence {
        admission.fence
    }

    /// Creates a compositor bound to one exact presentation generation.
    public init(
        fence: TerminalRenderPresentationFence,
        frameReleaseHandler: @escaping @Sendable (
            TerminalRenderFrameRelease
        ) -> Void,
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else {
            throw TerminalRenderCompositorError.metalDeviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw TerminalRenderCompositorError.commandQueueUnavailable
        }
        self.device = device
        self.frameReleaseHandler = frameReleaseHandler
        self.admission = TerminalRenderCompositorAdmission(fence: fence)
        let metalLayer = Self.makeLayer(device: device, fence: fence)
        let metalLayerHandle = TerminalRenderMetalLayerHandle(metalLayer)
        self.metalLayer = metalLayer
        self.metalLayerHandle = metalLayerHandle
        self.blitter = TerminalRenderMetalBlitter(
            device: device,
            commandQueue: commandQueue,
            initialEpoch: 1,
            initialLayer: metalLayerHandle,
            releaseHandler: frameReleaseHandler
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable, message: "Construct with an authenticated presentation fence")
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        let blitter = blitter
        Task {
            await blitter.stop()
        }
    }

    /// Installs a new generation on a new CAMetalLayer.
    ///
    /// Replacing the layer makes already committed frames from the prior
    /// generation present only to a detached layer, preventing cross-terminal
    /// or cross-generation pixels from becoming visible.
    public func updateFence(_ fence: TerminalRenderPresentationFence) {
        // This is a lifetime fence, so wrapping would make an ancient
        // completion indistinguishable from the current layer.
        submissionEpoch += 1
        admission.reset(fence: fence)
        let replacement = Self.makeLayer(device: device, fence: fence)
        let replacementHandle = TerminalRenderMetalLayerHandle(replacement)
        metalLayer = replacement
        metalLayerHandle = replacementHandle
        layer = replacement
        needsDisplay = true
        let epoch = submissionEpoch
        Task {
            await blitter.register(epoch: epoch, layer: replacementHandle)
        }
    }

    /// Admits a frame and submits, coalesces, or defers its single Metal blit.
    @discardableResult
    public func enqueue(
        _ frame: TerminalRenderFrame
    ) async -> TerminalRenderCompositorEnqueueResult {
        if let rejection = admission.accept(frame.metadata) {
            metadataRejectedFrames &+= 1
            frameReleaseHandler(TerminalRenderFrameRelease(frame: frame))
            return .rejected(rejection)
        }
        admittedFrames &+= 1
        return await blitter.enqueue(
            frame,
            epoch: submissionEpoch,
            layer: metalLayerHandle
        )
    }

    /// Snapshot of bounded admission and off-main blit counters.
    public func metricsSnapshot() async -> TerminalRenderCompositorMetrics {
        var result = await blitter.metrics()
        result.admittedFrames = admittedFrames
        result.rejectedFrames &+= metadataRejectedFrames
        return result
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retryPendingFrame()
    }

    public override func display() {
        super.display()
        retryPendingFrame()
    }

    private func retryPendingFrame() {
        let epoch = submissionEpoch
        let layer = metalLayerHandle
        Task {
            await blitter.retry(epoch: epoch, layer: layer)
        }
    }

    private static func makeLayer(
        device: any MTLDevice,
        fence: TerminalRenderPresentationFence
    ) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.pixelFormat = metalPixelFormat(fence.pixelFormat)
        layer.colorspace = colorSpace(fence.colorSpace)
        layer.drawableSize = CGSize(
            width: Int(fence.width),
            height: Int(fence.height)
        )
        layer.isOpaque = false
        if #available(macOS 10.15, *) {
            layer.wantsExtendedDynamicRangeContent = fence.colorSpace == .extendedLinearSRGB
        }
        return layer
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

    private static func colorSpace(
        _ colorSpace: TerminalRenderColorSpace
    ) -> CGColorSpace {
        switch colorSpace {
        case .sRGB:
            CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3:
            CGColorSpace(name: CGColorSpace.displayP3)!
        case .extendedLinearSRGB:
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        }
    }
}
