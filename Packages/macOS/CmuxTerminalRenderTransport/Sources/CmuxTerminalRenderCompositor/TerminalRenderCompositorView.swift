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
    /// Sendable ingress used by renderer receive tasks without entering the main actor.
    public nonisolated let frameIngress: TerminalRenderCompositorIngress
    private var submissionEpoch: UInt64 = 1
    private var retired = false

    /// Current exact presentation contract.
    public var fence: TerminalRenderPresentationFence {
        frameIngress.fence
    }

    /// Creates a compositor bound to one exact presentation generation.
    public init(
        fence: TerminalRenderPresentationFence,
        frameReleaseHandler: @escaping @Sendable (
            TerminalRenderFrameRelease
        ) -> Void,
        frameDispositionHandler: TerminalRenderFrameDispositionHandler? = nil,
        metricEventHandler: TerminalRenderCompositorMetricEventHandler? = nil,
        framePresentedHandler: TerminalRenderFramePresentedHandler? = nil,
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else {
            throw TerminalRenderCompositorError.metalDeviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw TerminalRenderCompositorError.commandQueueUnavailable
        }
        self.device = device
        let metalLayer = Self.makeLayer(device: device, fence: fence)
        let metalLayerHandle = TerminalRenderMetalLayerHandle(metalLayer)
        self.metalLayer = metalLayer
        self.metalLayerHandle = metalLayerHandle
        self.frameIngress = TerminalRenderCompositorIngress(
            device: device,
            commandQueue: commandQueue,
            fence: fence,
            initialLayer: metalLayerHandle,
            frameReleaseHandler: frameReleaseHandler,
            frameDispositionHandler: frameDispositionHandler,
            metricEventHandler: metricEventHandler,
            framePresentedHandler: framePresentedHandler
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
        frameIngress.stop()
    }

    /// Installs a new generation on a new CAMetalLayer.
    ///
    /// Replacing the layer makes already committed frames from the prior
    /// generation present only to a detached layer, preventing cross-terminal
    /// or cross-generation pixels from becoming visible.
    public func updateFence(_ fence: TerminalRenderPresentationFence) {
        guard !retired else { return }
        // This is a lifetime fence, so wrapping would make an ancient
        // completion indistinguishable from the current layer.
        submissionEpoch += 1
        let replacement = Self.makeLayer(device: device, fence: fence)
        let replacementHandle = TerminalRenderMetalLayerHandle(replacement)
        metalLayer = replacement
        metalLayerHandle = replacementHandle
        layer = replacement
        needsDisplay = true
        let epoch = submissionEpoch
        frameIngress.updateFence(fence, epoch: epoch, layer: replacementHandle)
    }

    /// Admits a frame and submits, coalesces, or defers its single Metal blit.
    @discardableResult
    public func enqueue(
        _ frame: TerminalRenderFrame
    ) async -> TerminalRenderCompositorEnqueueResult {
        await frameIngress.enqueue(frame)
    }

    /// Snapshot of bounded admission and off-main blit counters.
    public func metricsSnapshot() async -> TerminalRenderCompositorMetrics {
        await frameIngress.metricsSnapshot()
    }

    /// Synchronously detaches the drawable generation before an asynchronously
    /// received old-worker frame can re-enter the main actor during a move.
    public func retire() {
        guard !retired else { return }
        retired = true
        submissionEpoch += 1
        let replacement = Self.makeLayer(device: device, fence: frameIngress.fence)
        let replacementHandle = TerminalRenderMetalLayerHandle(replacement)
        metalLayer = replacement
        metalLayerHandle = replacementHandle
        layer = replacement
        frameIngress.retire(epoch: submissionEpoch, layer: replacementHandle)
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
        let frameIngress = frameIngress
        Task.detached {
            await frameIngress.retry()
        }
    }

    private static func makeLayer(
        device: any MTLDevice,
        fence: TerminalRenderPresentationFence
    ) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        // The host writes the drawable with MTLBlitCommandEncoder. Metal
        // forbids framebuffer-only textures from being used by a blit encoder.
        layer.framebufferOnly = false
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
