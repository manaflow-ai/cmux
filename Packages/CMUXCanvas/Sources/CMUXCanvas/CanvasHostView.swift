#if canImport(AppKit) && canImport(IOSurface) && canImport(MetalKit) && canImport(SwiftUI)
import AppKit
import CMUXLayout
import IOSurface
import MetalKit
import simd
import SwiftUI

public struct CanvasSurfaceTextureSource {
    public enum Backing {
        case ioSurface(IOSurfaceRef)
        case bitmap(CGImage, generation: UInt64)
    }

    public var id: LayoutItemID
    public var backing: Backing
    public var contentMode: CanvasTextureContentMode

    public init(
        id: LayoutItemID,
        surface: IOSurfaceRef,
        contentMode: CanvasTextureContentMode = .fit
    ) {
        self.id = id
        self.backing = .ioSurface(surface)
        self.contentMode = contentMode
    }

    public init(
        id: LayoutItemID,
        image: CGImage,
        generation: UInt64,
        contentMode: CanvasTextureContentMode = .fit
    ) {
        self.id = id
        self.backing = .bitmap(image, generation: generation)
        self.contentMode = contentMode
    }

    public var requiresContinuousRendering: Bool {
        if case .ioSurface = backing {
            return true
        }
        return false
    }
}

public final class CanvasHostView: NSView {
    private let metalView: MTKView
    private let renderer: CanvasMetalRenderer
    private var scene: CanvasScene
    private var style: CanvasShellStyle

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        style: CanvasShellStyle = CanvasShellStyle(),
        surfaceTextures: [CanvasSurfaceTextureSource] = [],
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.style = style
        let device = MTLCreateSystemDefaultDevice()
        self.metalView = MTKView(frame: .zero, device: device)
        self.renderer = CanvasMetalRenderer(
            backgroundColor: backgroundColor,
            scene: scene,
            style: style,
            surfaceTextures: surfaceTextures,
            device: device
        )
        super.init(frame: .zero)
        renderer.markNeedsRender()

        wantsLayer = true
        layer?.isOpaque = true

        metalView.delegate = renderer
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        metalView.layer?.isOpaque = true
        applyRenderLoopMode(surfaceTextures: surfaceTextures)

        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var currentScene: CanvasScene {
        scene
    }

    public func update(
        scene: CanvasScene,
        backgroundColor: NSColor,
        style: CanvasShellStyle = CanvasShellStyle(),
        surfaceTextures: [CanvasSurfaceTextureSource] = [],
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.style = style
        renderer.update(scene: scene, backgroundColor: backgroundColor, style: style, surfaceTextures: surfaceTextures)
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        applyRenderLoopMode(surfaceTextures: surfaceTextures)
    }

    private func applyRenderLoopMode(surfaceTextures: [CanvasSurfaceTextureSource]) {
        let mode = CanvasMetalRenderLoopMode.resolve(surfaceTextures: surfaceTextures)
        metalView.isPaused = mode.isPaused
        metalView.enableSetNeedsDisplay = mode.enableSetNeedsDisplay
        if mode.requestsImmediateDisplay {
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }
}

public struct CanvasHostRepresentable: NSViewRepresentable {
    public var scene: CanvasScene
    public var backgroundColor: NSColor
    public var style: CanvasShellStyle
    public var surfaceTextures: [CanvasSurfaceTextureSource]
    public var preferredFramesPerSecond: Int

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        style: CanvasShellStyle = CanvasShellStyle(),
        surfaceTextures: [CanvasSurfaceTextureSource] = [],
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.backgroundColor = backgroundColor
        self.style = style
        self.surfaceTextures = surfaceTextures
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(
            scene: scene,
            backgroundColor: backgroundColor,
            style: style,
            surfaceTextures: surfaceTextures,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: scene,
            backgroundColor: backgroundColor,
            style: style,
            surfaceTextures: surfaceTextures,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }
}

public struct CanvasMetalBackdrop: NSViewRepresentable {
    public var backgroundColor: NSColor
    public var preferredFramesPerSecond: Int

    public init(backgroundColor: NSColor, preferredFramesPerSecond: Int = 120) {
        self.backgroundColor = backgroundColor
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(
            scene: CanvasScene(),
            backgroundColor: backgroundColor,
            style: CanvasShellStyle(background: CanvasColor(nsColor: backgroundColor), cardFill: CanvasColor(nsColor: backgroundColor)),
            surfaceTextures: [],
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: CanvasScene(viewportSize: nsView.bounds.size),
            backgroundColor: backgroundColor,
            style: CanvasShellStyle(background: CanvasColor(nsColor: backgroundColor), cardFill: CanvasColor(nsColor: backgroundColor)),
            surfaceTextures: [],
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }
}

private final class CanvasMetalRenderer: NSObject, MTKViewDelegate {
    private struct RenderState {
        var backgroundColor: NSColor
        var scene: CanvasScene
        var style: CanvasShellStyle
        var surfaceTextures: [CanvasSurfaceTextureSource]
    }

    private let stateLock = NSLock()
    private var state: RenderState
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let shaderLibrary: MTLLibrary?
    private let textureLoader: MTKTextureLoader?
    private var pipelineState: MTLRenderPipelineState?
    private var pipelinePixelFormat: MTLPixelFormat?
    private var texturePipelineState: MTLRenderPipelineState?
    private var texturePipelinePixelFormat: MTLPixelFormat?
    private var iosurfaceTextureCache: [IOSurfaceID: CanvasMetalIOSurfaceTexture] = [:]
    private var bitmapTextureCache: [CanvasMetalBitmapTextureKey: CanvasMetalBitmapTexture] = [:]
    private var shellVertexBufferRing = CanvasMetalBufferRing<CanvasMetalVertex>()
    private var overlayVertexBufferRing = CanvasMetalBufferRing<CanvasMetalVertex>()
    private var textureVertexBufferRing = CanvasMetalBufferRing<CanvasMetalTextureVertex>()
    private var shellVertices: [CanvasMetalVertex] = []
    private var overlayVertices: [CanvasMetalVertex] = []
    private var textureVertices: [CanvasMetalTextureVertex] = []
    private var scheduler = CanvasFrameScheduler()

    init(
        backgroundColor: NSColor,
        scene: CanvasScene,
        style: CanvasShellStyle,
        surfaceTextures: [CanvasSurfaceTextureSource],
        device: MTLDevice?
    ) {
        self.state = RenderState(
            backgroundColor: backgroundColor,
            scene: scene,
            style: style,
            surfaceTextures: surfaceTextures
        )
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.shaderLibrary = CanvasMetalShaderLibrary.makeLibrary(device: device)
        self.textureLoader = device.map(MTKTextureLoader.init(device:))
        super.init()
    }

    var clearColor: MTLClearColor {
        Self.clearColor(for: stateLock.withLock { state.backgroundColor })
    }

    private static func clearColor(for backgroundColor: NSColor) -> MTLClearColor {
        let color = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
        return MTLClearColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: 1
        )
    }

    func update(
        scene: CanvasScene,
        backgroundColor: NSColor,
        style: CanvasShellStyle,
        surfaceTextures: [CanvasSurfaceTextureSource]
    ) {
        stateLock.withLock {
            self.state = RenderState(
                backgroundColor: backgroundColor,
                scene: scene,
                style: style,
                surfaceTextures: surfaceTextures
            )
            scheduler.markNeedsRender()
        }
    }

    func markNeedsRender() {
        stateLock.withLock {
            scheduler.markNeedsRender()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        stateLock.withLock {
            state.scene = CanvasScene(
                viewport: state.scene.viewport,
                viewportSize: size,
                scale: state.scene.scale,
                padding: state.scene.padding,
                minimumSurfaceDisplaySize: state.scene.minimumSurfaceDisplaySize,
                grid: state.scene.grid,
                surfaces: state.scene.surfaces,
                alignmentGuides: state.scene.alignmentGuides
            )
            scheduler.markNeedsRender()
        }
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        let renderState: RenderState? = stateLock.withLock {
            let hasLiveSurfaceTextures = self.state.surfaceTextures.contains {
                $0.requiresContinuousRendering
            }
            guard scheduler.consumeFrame() || hasLiveSurfaceTextures else { return nil }
            return self.state
        }
        guard let state = renderState else { return }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return
        }
        descriptor.colorAttachments[0].clearColor = Self.clearColor(for: state.backgroundColor)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let plan = CanvasShellRenderPlan(scene: state.scene, style: state.style)
        let viewport = SIMD2<Float>(
            Float(max(1, view.bounds.width)),
            Float(max(1, view.bounds.height))
        )
        if let pipelineState = pipelineState(for: view),
           let vertexBuffer = vertexBuffer(for: plan) {
            var viewport = viewport
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexBuffer.vertexCount)
        }

        drawSurfaceTextures(
            for: plan,
            surfaceTextures: state.surfaceTextures,
            viewport: viewport,
            encoder: encoder,
            view: view
        )

        if let pipelineState = pipelineState(for: view),
           let vertexBuffer = overlayVertexBuffer(for: plan, style: state.style) {
            var viewport = viewport
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexBuffer.vertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func pipelineState(for view: MTKView) -> MTLRenderPipelineState? {
        guard let device, let shaderLibrary else { return nil }
        if pipelinePixelFormat == view.colorPixelFormat {
            return pipelineState
        }

        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = shaderLibrary.makeFunction(name: "cmux_canvas_vertex")
            descriptor.fragmentFunction = shaderLibrary.makeFunction(name: "cmux_canvas_fragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineState = pipeline
            pipelinePixelFormat = view.colorPixelFormat
            return pipeline
        } catch {
            pipelineState = nil
            pipelinePixelFormat = nil
            return nil
        }
    }

    private func texturePipelineState(for view: MTKView) -> MTLRenderPipelineState? {
        guard let device, let shaderLibrary else { return nil }
        if texturePipelinePixelFormat == view.colorPixelFormat {
            return texturePipelineState
        }

        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = shaderLibrary.makeFunction(name: "cmux_canvas_texture_vertex")
            descriptor.fragmentFunction = shaderLibrary.makeFunction(name: "cmux_canvas_texture_fragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            CanvasMetalPremultipliedBlending.configure(descriptor.colorAttachments[0])
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            texturePipelineState = pipeline
            texturePipelinePixelFormat = view.colorPixelFormat
            return pipeline
        } catch {
            texturePipelineState = nil
            texturePipelinePixelFormat = nil
            return nil
        }
    }

    private func vertexBuffer(for plan: CanvasShellRenderPlan) -> CanvasMetalVertexBuffer? {
        guard let device else { return nil }
        shellVertices.removeAll(keepingCapacity: true)
        shellVertices.reserveCapacity(plan.primitives.count * 6)
        for primitive in plan.primitives {
            append(primitive, to: &shellVertices)
        }
        return shellVertexBufferRing.nextBuffer(device: device, vertices: shellVertices)
    }

    private func overlayVertexBuffer(for plan: CanvasShellRenderPlan, style: CanvasShellStyle) -> CanvasMetalVertexBuffer? {
        guard let device else { return nil }
        overlayVertices.removeAll(keepingCapacity: true)
        overlayVertices.reserveCapacity(plan.surfaces.count * 24)
        for surface in plan.surfaces {
            append(.fill(CanvasShellRect(rect: surface.headerFrame, color: style.headerFill)), to: &overlayVertices)
            append(.stroke(
                rect: surface.frame,
                width: surface.isFocused ? style.focusedBorderWidth : style.borderWidth,
                color: surface.isFocused ? style.focusedBorder : style.border
            ), to: &overlayVertices)
        }
        return overlayVertexBufferRing.nextBuffer(device: device, vertices: overlayVertices)
    }

    private func drawSurfaceTextures(
        for plan: CanvasShellRenderPlan,
        surfaceTextures: [CanvasSurfaceTextureSource],
        viewport: SIMD2<Float>,
        encoder: MTLRenderCommandEncoder,
        view: MTKView
    ) {
        guard let device,
              let pipelineState = texturePipelineState(for: view) else { return }
        pruneTextureCache(keeping: surfaceTextures)
        let sources = Dictionary(uniqueKeysWithValues: surfaceTextures.map { ($0.id, $0) })
        guard !sources.isEmpty else { return }

        textureVertices.removeAll(keepingCapacity: true)
        var draws: [CanvasMetalTextureDraw] = []
        draws.reserveCapacity(plan.surfaces.count)
        for surface in plan.surfaces where surface.renderMode != .nativeOverlay {
            guard let source = sources[surface.id],
                  let texture = metalTexture(for: source) else { continue }
            let frame = textureFrame(
                in: surface.contentFrame,
                textureSize: CGSize(width: texture.width, height: texture.height),
                contentMode: source.contentMode
            )
            let vertexStart = textureVertices.count
            appendTextureRect(frame, to: &textureVertices)
            let vertexCount = textureVertices.count - vertexStart
            guard vertexCount > 0 else { continue }
            draws.append(CanvasMetalTextureDraw(texture: texture, vertexStart: vertexStart, vertexCount: vertexCount))
        }

        guard let vertexBuffer = textureVertexBufferRing.nextBuffer(device: device, vertices: textureVertices),
              !draws.isEmpty else { return }

        var viewport = viewport
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer.buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for draw in draws {
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: draw.vertexStart, vertexCount: draw.vertexCount)
        }
    }

    private func metalTexture(for source: CanvasSurfaceTextureSource) -> MTLTexture? {
        switch source.backing {
        case .ioSurface(let surface):
            return metalTexture(for: surface)
        case .bitmap(let image, let generation):
            return metalTexture(for: image, sourceID: source.id, generation: generation)
        }
    }

    private func metalTexture(for surface: IOSurfaceRef) -> MTLTexture? {
        guard let device else { return nil }
        let surfaceID = IOSurfaceGetID(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }

        if let cached = iosurfaceTextureCache[surfaceID],
           cached.width == width,
           cached.height == height {
            return cached.texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            iosurfaceTextureCache.removeValue(forKey: surfaceID)
            return nil
        }

        iosurfaceTextureCache[surfaceID] = CanvasMetalIOSurfaceTexture(texture: texture, width: width, height: height)
        return texture
    }

    private func metalTexture(for image: CGImage, sourceID: LayoutItemID, generation: UInt64) -> MTLTexture? {
        let key = CanvasMetalBitmapTextureKey(sourceID: sourceID, generation: generation)
        if let cached = bitmapTextureCache[key],
           cached.width == image.width,
           cached.height == image.height {
            return cached.texture
        }

        guard let texture = try? textureLoader?.newTexture(
            cgImage: image,
            options: [
                MTKTextureLoader.Option.SRGB: false,
                MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue,
            ]
        ) else {
            bitmapTextureCache.removeValue(forKey: key)
            return nil
        }

        bitmapTextureCache[key] = CanvasMetalBitmapTexture(texture: texture, width: image.width, height: image.height)
        return texture
    }

    private func pruneTextureCache(keeping sources: [CanvasSurfaceTextureSource]) {
        var surfaceIDs: Set<IOSurfaceID> = []
        var bitmapKeys: Set<CanvasMetalBitmapTextureKey> = []
        for source in sources {
            switch source.backing {
            case .ioSurface(let surface):
                surfaceIDs.insert(IOSurfaceGetID(surface))
            case .bitmap(_, let generation):
                bitmapKeys.insert(CanvasMetalBitmapTextureKey(sourceID: source.id, generation: generation))
            }
        }
        iosurfaceTextureCache = iosurfaceTextureCache.filter { surfaceIDs.contains($0.key) }
        bitmapTextureCache = bitmapTextureCache.filter { bitmapKeys.contains($0.key) }
    }

    private func textureFrame(
        in contentFrame: CGRect,
        textureSize: CGSize,
        contentMode: CanvasTextureContentMode
    ) -> CGRect {
        let contentFrame = contentFrame.standardized
        guard contentFrame.width > 1,
              contentFrame.height > 1,
              textureSize.width > 1,
              textureSize.height > 1 else {
            return contentFrame
        }

        let scale: CGFloat
        switch contentMode {
        case .fit:
            scale = min(contentFrame.width / textureSize.width, contentFrame.height / textureSize.height)
        case .fill:
            scale = max(contentFrame.width / textureSize.width, contentFrame.height / textureSize.height)
        }
        let width = textureSize.width * scale
        let height = textureSize.height * scale
        return CGRect(
            x: contentFrame.midX - (width / 2),
            y: contentFrame.midY - (height / 2),
            width: width,
            height: height
        )
    }

    private func appendTextureRect(_ frame: CGRect, to vertices: inout [CanvasMetalTextureVertex]) {
        let rect = frame.standardized
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.minX), Float(rect.minY)), texCoord: SIMD2<Float>(0, 0)))
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.maxX), Float(rect.minY)), texCoord: SIMD2<Float>(1, 0)))
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.minX), Float(rect.maxY)), texCoord: SIMD2<Float>(0, 1)))
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.minX), Float(rect.maxY)), texCoord: SIMD2<Float>(0, 1)))
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.maxX), Float(rect.minY)), texCoord: SIMD2<Float>(1, 0)))
        vertices.append(CanvasMetalTextureVertex(position: SIMD2<Float>(Float(rect.maxX), Float(rect.maxY)), texCoord: SIMD2<Float>(1, 1)))
    }

    private func append(_ primitive: CanvasShellPrimitive, to vertices: inout [CanvasMetalVertex]) {
        switch primitive {
        case .fill(let rect):
            appendRect(rect.rect, color: rect.color, to: &vertices)
        case .stroke(let rect, let width, let color):
            appendLine(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), width: width, color: color, vertices: &vertices)
            appendLine(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), width: width, color: color, vertices: &vertices)
            appendLine(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY), width: width, color: color, vertices: &vertices)
            appendLine(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), width: width, color: color, vertices: &vertices)
        case .line(let line):
            appendLine(from: line.start, to: line.end, width: line.width, color: line.color, vertices: &vertices)
        }
    }

    private func appendRect(_ rect: CGRect, color: CanvasColor, to vertices: inout [CanvasMetalVertex]) {
        let rect = rect.standardized
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let p0 = CGPoint(x: rect.minX, y: rect.minY)
        let p1 = CGPoint(x: rect.maxX, y: rect.minY)
        let p2 = CGPoint(x: rect.minX, y: rect.maxY)
        let p3 = CGPoint(x: rect.maxX, y: rect.maxY)
        appendTriangle(p0, p1, p2, color: color, vertices: &vertices)
        appendTriangle(p2, p1, p3, color: color, vertices: &vertices)
    }

    private func appendLine(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat,
        color: CanvasColor,
        vertices: inout [CanvasMetalVertex]
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.0001, hypot(dx, dy))
        let halfWidth = max(0.5, width) / 2
        let normal = CGPoint(x: -(dy / length) * halfWidth, y: (dx / length) * halfWidth)
        let p0 = CGPoint(x: start.x + normal.x, y: start.y + normal.y)
        let p1 = CGPoint(x: end.x + normal.x, y: end.y + normal.y)
        let p2 = CGPoint(x: start.x - normal.x, y: start.y - normal.y)
        let p3 = CGPoint(x: end.x - normal.x, y: end.y - normal.y)
        appendTriangle(p0, p1, p2, color: color, vertices: &vertices)
        appendTriangle(p2, p1, p3, color: color, vertices: &vertices)
    }

    private func appendTriangle(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        color: CanvasColor,
        vertices: inout [CanvasMetalVertex]
    ) {
        let color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
        vertices.append(CanvasMetalVertex(position: SIMD2<Float>(Float(a.x), Float(a.y)), color: color))
        vertices.append(CanvasMetalVertex(position: SIMD2<Float>(Float(b.x), Float(b.y)), color: color))
        vertices.append(CanvasMetalVertex(position: SIMD2<Float>(Float(c.x), Float(c.y)), color: color))
    }

}

private struct CanvasMetalVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct CanvasMetalVertexBuffer {
    var buffer: MTLBuffer
    var vertexCount: Int
}

private struct CanvasMetalBufferRing<Vertex> {
    private var buffers: [MTLBuffer?] = Array(repeating: nil, count: 3)
    private var index = 0

    mutating func nextBuffer(device: MTLDevice, vertices: [Vertex]) -> CanvasMetalVertexBuffer? {
        guard !vertices.isEmpty else { return nil }
        index = (index + 1) % buffers.count
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        if buffers[index] == nil || buffers[index]!.length < byteCount {
            let capacity = Self.alignedCapacity(for: byteCount)
            buffers[index] = device.makeBuffer(length: capacity, options: .storageModeShared)
        }
        guard let buffer = buffers[index] else { return nil }
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
        }
        return CanvasMetalVertexBuffer(buffer: buffer, vertexCount: vertices.count)
    }

    private static func alignedCapacity(for byteCount: Int) -> Int {
        let alignment = 4_096
        return ((max(1, byteCount) + alignment - 1) / alignment) * alignment
    }
}

private struct CanvasMetalTextureVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct CanvasMetalTextureDraw {
    var texture: MTLTexture
    var vertexStart: Int
    var vertexCount: Int
}

enum CanvasMetalPremultipliedBlending {
    static func configure(_ colorAttachment: MTLRenderPipelineColorAttachmentDescriptor?) {
        colorAttachment?.isBlendingEnabled = true
        colorAttachment?.sourceRGBBlendFactor = .one
        colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.rgbBlendOperation = .add
        colorAttachment?.sourceAlphaBlendFactor = .one
        colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.alphaBlendOperation = .add
    }
}

struct CanvasMetalRenderLoopMode: Equatable {
    var isPaused: Bool
    var enableSetNeedsDisplay: Bool
    var requestsImmediateDisplay: Bool

    static func resolve(surfaceTextures: [CanvasSurfaceTextureSource]) -> CanvasMetalRenderLoopMode {
        let hasContinuousTexture = surfaceTextures.contains { $0.requiresContinuousRendering }
        return CanvasMetalRenderLoopMode(
            isPaused: !hasContinuousTexture,
            enableSetNeedsDisplay: !hasContinuousTexture,
            requestsImmediateDisplay: !hasContinuousTexture
        )
    }
}

private struct CanvasMetalIOSurfaceTexture {
    var texture: MTLTexture
    var width: Int
    var height: Int
}

private struct CanvasMetalBitmapTextureKey: Hashable {
    var sourceID: LayoutItemID
    var generation: UInt64
}

private struct CanvasMetalBitmapTexture {
    var texture: MTLTexture
    var width: Int
    var height: Int
}

enum CanvasMetalShaderLibrary {
    static func makeLibrary(device: MTLDevice?) -> MTLLibrary? {
        guard let device else { return nil }
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let packageLibrary = try? device.makeLibrary(URL: url) {
            return packageLibrary
        }
#endif
        return device.makeDefaultLibrary()
    }
}

private extension CanvasColor {
    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        self.init(
            red: Float(color.redComponent),
            green: Float(color.greenComponent),
            blue: Float(color.blueComponent),
            alpha: Float(color.alphaComponent)
        )
    }
}
#endif
