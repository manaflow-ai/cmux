internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import Dispatch
internal import Metal

/// Result of one indivisible host full-surface blit attempt.
enum TerminalRenderMetalBackendSubmissionResult: Equatable, Sendable {
    case submitted
    case drawableUnavailable
    case invalidSurface
    case metalUnavailable
}

/// GPU lifecycle callbacks for one exact submitted frame.
struct TerminalRenderMetalSubmissionCallbacks: Sendable {
    let completed: @Sendable () -> Void
    let presented: @Sendable () -> Void
}

/// Narrow test seam representing the host's entire permitted Metal operation.
///
/// Implementations submit one command buffer containing one blit encoder and
/// one full-surface copy. The compositor never exposes MTL protocol trees to
/// tests and has no render-encoder operation in this interface.
protocol TerminalRenderMetalSubmitting: AnyObject, Sendable {
    func submitOneFullSurfaceBlit(
        frame: TerminalRenderFrame,
        layer: TerminalRenderMetalLayerHandle,
        callbacks: TerminalRenderMetalSubmissionCallbacks
    ) -> TerminalRenderMetalBackendSubmissionResult

    func invalidateSourceTextureCache()
}

/// Production implementation of the host's single permitted Metal operation.
final class TerminalRenderMetalSubmissionBackend:
    TerminalRenderMetalSubmitting,
    @unchecked Sendable
{
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache = TerminalRenderMetalSourceTextureCache<any MTLTexture>()

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
    }

    func submitOneFullSurfaceBlit(
        frame: TerminalRenderFrame,
        layer: TerminalRenderMetalLayerHandle,
        callbacks: TerminalRenderMetalSubmissionCallbacks
    ) -> TerminalRenderMetalBackendSubmissionResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let sourceTexture = sourceTexture(for: frame) else {
            return .invalidSurface
        }
        guard let drawable = layer.layer.nextDrawable() else {
            return .drawableUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
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

        drawable.addPresentedHandler { _ in
            callbacks.presented()
        }
        commandBuffer.addCompletedHandler { _ in
            // The command buffer completion is the worker's exact surface
            // reuse fence. Keep the imported texture alive until this point.
            _ = sourceTexture
            callbacks.completed()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return .submitted
    }

    func invalidateSourceTextureCache() {
        textureCache.removeAll()
    }

    private func sourceTexture(for frame: TerminalRenderFrame) -> (any MTLTexture)? {
        let key = TerminalRenderMetalSourceTextureCacheKey(frame: frame)
        if let cached = textureCache.value(for: key) {
            return cached
        }

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
        guard let texture = frame.surface.withIOSurface({ surface in
            device.makeTexture(
                descriptor: descriptor,
                iosurface: surface,
                plane: 0
            )
        }) else {
            return nil
        }
        textureCache.insert(texture, for: key)
        return texture
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
