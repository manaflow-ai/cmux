import CmuxNextCompat
import CoreGraphics
public import Foundation
import ImageIO
import OSLog
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// Draws ``BackdropShader``s with Metal: live frames into a window's `CAMetalLayer`
/// (``BackdropShaderView``) and stills into files (``preparePoster(at:)``).
///
/// The app's image store owns one (``BackdropImageStore/shaders``), shared by every window: the
/// device, the library compiled from ``BackdropShaderSource`` and one pipeline per shader are made once.
/// A poster still is rendered by a renderer made for it, once per shader, appearance and version. Live frames are encoded on
/// ``queue``, a serial queue off the main thread, so a drawable that is slow to come back never
/// stalls the main thread; a view sends its next frame only after the last one was encoded.
public nonisolated final class BackdropShaderRenderer: Sendable {
    /// The serial queue live frames are encoded on.
    let queue = DispatchQueue(label: "cmux.backdrop-shader.render", qos: .userInitiated)
    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let state = Mutex(State())

    /// The compiled library (nil until first use, or after it failed) and one pipeline per shader.
    private struct State {
        var library: (any MTLLibrary)?
        var libraryFailed = false
        var pipelines: [BackdropShader: any MTLRenderPipelineState] = [:]
    }

    /// The pixel format of every target: the layer's and the posters'.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// The system's default GPU; nil on a Mac without Metal (the backdrop then shows the theme's colors).
    public convenience init?() {
        self.init(device: MTLCreateSystemDefaultDevice())
    }

    init?(device: (any MTLDevice)?) {
        guard let device, let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
    }

    /// The pipeline drawing `shader`, compiling the library on first use; nil when the source does
    /// not compile (logged once).
    func pipeline(_ shader: BackdropShader) -> (any MTLRenderPipelineState)? {
        state.withLock { state in
            if let pipeline = state.pipelines[shader] { return pipeline }
            if state.library == nil, !state.libraryFailed {
                do {
                    state.library = try device.makeLibrary(source: BackdropShaderSource.source, options: nil)
                } catch {
                    state.libraryFailed = true
                    Self.log.error("backdrop shader library failed to compile: \(String(describing: error), privacy: .public)")
                }
            }
            guard let library = state.library, let vertex = library.makeFunction(name: "wp_vertex"),
                  let fragment = library.makeFunction(name: shader.fragmentName) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            state.pipelines[shader] = pipeline
            return pipeline
        }
    }

    /// Encodes one frame of `shader` into `layer`'s next drawable and presents it. On ``queue``.
    /// Returns false when no frame was drawn (no pipeline, no drawable within the layer's timeout).
    @discardableResult
    func draw(_ shader: BackdropShader, uniforms: BackdropShaderUniforms, into target: BackdropShaderTarget) -> Bool {
        let layer = target.layer
        let size = CGSize(width: CGFloat(uniforms.resolution.x), height: CGFloat(uniforms.resolution.y))
        if layer.drawableSize != size {
            // An explicit transaction: this queue has no run loop to commit an implicit one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = size
            CATransaction.commit()
        }
        guard let pipeline = pipeline(shader), let drawable = layer.nextDrawable(),
              let commands = commandQueue.makeCommandBuffer() else { return false }
        encode(pipeline, uniforms: uniforms, target: drawable.texture, commands: commands)
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// One still of `shader` at `size` pixels: what ``preparePoster(at:)`` writes. Waits for the
    /// GPU, so it runs off the main thread only (image decodes, thumbnails).
    func still(_ shader: BackdropShader, width: Int, height: Int, dark: Bool) -> CGImage? {
        guard width > 0, height > 0, let pipeline = pipeline(shader) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = commandQueue.makeCommandBuffer() else { return nil }
        var uniforms = BackdropShaderUniforms()
        uniforms.resolution = SIMD2(Float(width), Float(height))
        // The pointer rests left of center, a little high: the still shows what it does.
        uniforms.mouse = SIMD2(Float(width) * 0.38, Float(height) * 0.58)
        uniforms.time = shader.startTime
        uniforms.energy = 0.35
        uniforms.dark = dark ? 1 : 0
        encode(pipeline, uniforms: uniforms, target: texture, commands: commands)
        if let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        // concurrency-allow: stills render only off the main thread (BackdropImageStore's detached
        // decode, the settings thumbnail's detached read); the wait is one small offscreen frame.
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private func encode(_ pipeline: any MTLRenderPipelineState, uniforms: BackdropShaderUniforms,
                        target: any MTLTexture, commands: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackdropShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The poster's size: 16:10 at a width that fills a window's art layer softly (the live layer
    /// covers it once its first frame is drawn).
    static let posterSize = (width: 1600, height: 1000)

    /// Renders the still `url` names (``BackdropShader/posterURL(dark:)``) when it is a shader
    /// poster that is not on disk yet; any other file is left alone. Off the main thread only.
    public static func preparePoster(at url: URL) {
        // On the main thread a missing still stays missing: the next decode, off main, renders it.
        guard !Thread.isMainThread, let poster = BackdropShader.poster(at: url),
              !FileManager.checked.fileExists(atPath: url.path), let renderer = BackdropShaderRenderer(),
              let image = renderer.still(poster.shader, width: posterSize.width, height: posterSize.height, dark: poster.dark)
        else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(UUID().uuidString + ".partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.checked.removeItem(at: partial)
            return
        }
        // Another decode may have written it meanwhile: either copy is the same still.
        if (try? FileManager.checked.moveItem(at: partial, to: url)) == nil {
            try? FileManager.checked.removeItem(at: partial)
        }
    }

    /// `url`, after rendering it when it is a shader poster not on disk yet (``preparePoster(at:)``).
    public static func prepared(_ url: URL) -> URL {
        preparePoster(at: url)
        return url
    }

    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "backdrop-shader")
}
