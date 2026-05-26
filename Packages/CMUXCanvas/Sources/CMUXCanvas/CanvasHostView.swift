#if canImport(AppKit) && canImport(MetalKit) && canImport(SwiftUI)
import AppKit
import CMUXLayout
import MetalKit
import simd
import SwiftUI

public final class CanvasHostView: NSView {
    private let metalView: MTKView
    private let renderer: CanvasMetalRenderer
    private var scene: CanvasScene
    private var style: CanvasShellStyle

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        style: CanvasShellStyle = CanvasShellStyle(),
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
            device: device
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.isOpaque = true

        metalView.delegate = renderer
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        metalView.layer?.isOpaque = true

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
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.style = style
        renderer.update(scene: scene, backgroundColor: backgroundColor, style: style)
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        metalView.setNeedsDisplay(metalView.bounds)
    }
}

public struct CanvasHostRepresentable: NSViewRepresentable {
    public var scene: CanvasScene
    public var backgroundColor: NSColor
    public var style: CanvasShellStyle
    public var preferredFramesPerSecond: Int

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        style: CanvasShellStyle = CanvasShellStyle(),
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.backgroundColor = backgroundColor
        self.style = style
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(
            scene: scene,
            backgroundColor: backgroundColor,
            style: style,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: scene,
            backgroundColor: backgroundColor,
            style: style,
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
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: CanvasScene(viewportSize: nsView.bounds.size),
            backgroundColor: backgroundColor,
            style: CanvasShellStyle(background: CanvasColor(nsColor: backgroundColor), cardFill: CanvasColor(nsColor: backgroundColor)),
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }
}

private final class CanvasMetalRenderer: NSObject, MTKViewDelegate {
    private var backgroundColor: NSColor
    private var scene: CanvasScene
    private var style: CanvasShellStyle
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var pipelinePixelFormat: MTLPixelFormat?
    private var scheduler = CanvasFrameScheduler()

    init(backgroundColor: NSColor, scene: CanvasScene, style: CanvasShellStyle, device: MTLDevice?) {
        self.backgroundColor = backgroundColor
        self.scene = scene
        self.style = style
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        super.init()
    }

    var clearColor: MTLClearColor {
        let color = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
        return MTLClearColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: 1
        )
    }

    func update(scene: CanvasScene, backgroundColor: NSColor, style: CanvasShellStyle) {
        self.scene = scene
        self.backgroundColor = backgroundColor
        self.style = style
        scheduler.markNeedsRender()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene = CanvasScene(
            viewport: scene.viewport,
            viewportSize: size,
            scale: scene.scale,
            padding: scene.padding,
            minimumSurfaceDisplaySize: scene.minimumSurfaceDisplaySize,
            grid: scene.grid,
            surfaces: scene.surfaces,
            alignmentGuides: scene.alignmentGuides
        )
        scheduler.markNeedsRender()
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard scheduler.consumeFrame() else { return }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let plan = CanvasShellRenderPlan(scene: scene, style: style)
        if let pipelineState = pipelineState(for: view),
           let buffer = vertexBuffer(for: plan) {
            var viewport = SIMD2<Float>(
                Float(max(1, view.bounds.width)),
                Float(max(1, view.bounds.height))
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buffer.length / MemoryLayout<CanvasMetalVertex>.stride)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func pipelineState(for view: MTKView) -> MTLRenderPipelineState? {
        guard let device else { return nil }
        if pipelinePixelFormat == view.colorPixelFormat {
            return pipelineState
        }

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cmux_canvas_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cmux_canvas_fragment")
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

    private func vertexBuffer(for plan: CanvasShellRenderPlan) -> MTLBuffer? {
        guard let device else { return nil }
        var vertices: [CanvasMetalVertex] = []
        vertices.reserveCapacity(plan.primitives.count * 6)
        for primitive in plan.primitives {
            append(primitive, to: &vertices)
        }
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
        }
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

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CanvasVertex {
        packed_float2 position;
        packed_float4 color;
    };

    struct CanvasRasterVertex {
        float4 position [[position]];
        float4 color;
    };

    vertex CanvasRasterVertex cmux_canvas_vertex(
        uint vertexID [[vertex_id]],
        const device CanvasVertex *vertices [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]]
    ) {
        CanvasVertex input = vertices[vertexID];
        float2 safeViewport = max(viewport, float2(1.0, 1.0));
        float2 ndc = float2(
            (input.position.x / safeViewport.x) * 2.0 - 1.0,
            1.0 - (input.position.y / safeViewport.y) * 2.0
        );
        CanvasRasterVertex output;
        output.position = float4(ndc, 0.0, 1.0);
        output.color = input.color;
        return output;
    }

    fragment float4 cmux_canvas_fragment(CanvasRasterVertex input [[stage_in]]) {
        return input.color;
    }
    """
}

private struct CanvasMetalVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
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
