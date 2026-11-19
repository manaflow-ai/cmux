import CmuxNextCompat
import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Draws a live wallpaper's frames into its view's `CAMetalLayer`, off the main thread.
///
/// The main thread only packs the 144-byte Frame uniform and hands it here; `nextDrawable` (which
/// may wait for the compositor to give a drawable back), the encode and the commit run on one
/// serial render queue shared by every window (``LiveWallpaperPrograms/renderQueue``). At most one
/// frame of a view is in flight: a display link tick that finds the last frame still on the GPU
/// draws nothing (``draw(_:pipeline:drawableSize:completed:)`` answers false), so a slow GPU lowers
/// the frame rate instead of queueing frames. The command
/// buffer's GPU start and end times go back to the view for the scheduler's GPU strikes.
// The layer is configured on main before the first frame, then touched only on `queue`.
// crash-allow: `layer` after setup only on the serial `queue` (drawableSize, nextDrawable); `gpu` immutable; `busy` a Mutex.
nonisolated final class LiveWallpaperRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let gpu: LiveWallpaperGPU
    /// The serial render queue every live wallpaper shares (``LiveWallpaperPrograms/renderQueue``).
    private let queue: DispatchQueue
    // concurrency-allow: one flag, set by the main thread and cleared by the render queue or Metal's completion thread; no I/O under it.
    private let busy = Mutex(false)

    init(layer: CAMetalLayer, gpu: LiveWallpaperGPU, queue: DispatchQueue) {
        self.layer = layer
        self.gpu = gpu
        self.queue = queue
    }

    /// Queues one frame of `uniform` (36 floats) at `drawableSize` pixels. False when the previous
    /// frame is still in flight (nothing is queued). `completed` gets the frame's GPU time in
    /// milliseconds, or nil when it could not be drawn, on a thread of Metal's or the render queue.
    func draw(_ uniform: [Float], pipeline: LiveWallpaperPipeline, drawableSize: CGSize,
              completed: @escaping @Sendable (Double?) -> Void) -> Bool {
        let claimed = busy.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard claimed else { return false }
        queue.async { [self] in
            guard encode(uniform, pipeline: pipeline, drawableSize: drawableSize, completed: completed) else {
                busy.withLock { $0 = false }
                completed(nil)
                return
            }
        }
        return true
    }

    private func encode(_ uniform: [Float], pipeline: LiveWallpaperPipeline, drawableSize: CGSize,
                        completed: @escaping @Sendable (Double?) -> Void) -> Bool {
        if layer.drawableSize != drawableSize {
            // An explicit transaction: this thread has no run loop to commit an implicit one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = drawableSize
            CATransaction.commit()
        }
        guard let drawable = layer.nextDrawable(), let commands = gpu.queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        // The full-screen triangle writes every pixel.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        Self.encodeFrame(encoder, uniform: uniform, pipeline: pipeline)
        commands.addCompletedHandler { [self] buffer in
            let milliseconds = buffer.status == .completed ? (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 : nil
            busy.withLock { $0 = false }
            completed(milliseconds)
        }
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// The one draw: the pipeline, the Frame uniform at buffer 0 of both stages, a full-screen triangle.
    static func encodeFrame(_ encoder: any MTLRenderCommandEncoder, uniform: [Float], pipeline: LiveWallpaperPipeline) {
        encoder.setRenderPipelineState(pipeline.state)
        uniform.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setVertexBytes(base, length: bytes.count, index: 0)
            encoder.setFragmentBytes(base, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One frame of `uniform` drawn off screen at `width` x `height` pixels and read back: a
    /// wallpaper's still (its picker thumbnail, the light field's picture). Never on the main
    /// thread's time: the GPU's completion resumes it.
    @concurrent
    static func still(_ uniform: [Float], pipeline: LiveWallpaperPipeline, width: Int, height: Int) async -> CGImage? {
        guard width > 0, height > 0, let gpu = LiveWallpaperGPU.shared else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LiveWallpaperGPU.pixelFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let readback = gpu.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commands = gpu.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeFrame(encoder, uniform: uniform, pipeline: pipeline)
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        let target = LiveWallpaperReadback(readback)
        let drawn: Bool = await withCheckedContinuation { continuation in
            commands.addCompletedHandler { buffer in continuation.resume(returning: buffer.status == .completed) }
            commands.commit()
        }
        guard drawn else { return nil }
        let data = Data(bytes: target.buffer.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // BGRA in memory, premultiplied, sRGB-encoded by the program's epilogue.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

/// The still's readback buffer, kept across the wait for the GPU.
// crash-allow: immutable after init; the GPU's write completes before the buffer is read.
private nonisolated final class LiveWallpaperReadback: @unchecked Sendable {
    let buffer: any MTLBuffer

    init(_ buffer: any MTLBuffer) {
        self.buffer = buffer
    }
}
