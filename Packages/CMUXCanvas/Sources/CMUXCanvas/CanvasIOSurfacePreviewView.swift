#if canImport(AppKit) && canImport(IOSurface) && canImport(MetalKit) && canImport(SwiftUI)
import AppKit
import IOSurface
import MetalKit
import SwiftUI

public struct CanvasIOSurfacePreview: NSViewRepresentable {
    public enum ContentMode: Sendable, Equatable {
        case fit
        case fill
    }

    public var surface: IOSurfaceRef?
    public var backgroundColor: NSColor
    public var contentMode: ContentMode
    public var preferredFramesPerSecond: Int

    public init(
        surface: IOSurfaceRef?,
        backgroundColor: NSColor,
        contentMode: ContentMode = .fit,
        preferredFramesPerSecond: Int = 120
    ) {
        self.surface = surface
        self.backgroundColor = backgroundColor
        self.contentMode = contentMode
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    public func makeNSView(context: Context) -> CanvasIOSurfacePreviewHostView {
        CanvasIOSurfacePreviewHostView(
            surface: surface,
            backgroundColor: backgroundColor,
            contentMode: contentMode,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasIOSurfacePreviewHostView, context: Context) {
        nsView.update(
            surface: surface,
            backgroundColor: backgroundColor,
            contentMode: contentMode,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }
}

public final class CanvasIOSurfacePreviewHostView: NSView {
    private let metalView: MTKView
    private let renderer: CanvasIOSurfacePreviewRenderer

    public init(
        surface: IOSurfaceRef?,
        backgroundColor: NSColor,
        contentMode: CanvasIOSurfacePreview.ContentMode,
        preferredFramesPerSecond: Int
    ) {
        let device = MTLCreateSystemDefaultDevice()
        self.metalView = MTKView(frame: .zero, device: device)
        self.renderer = CanvasIOSurfacePreviewRenderer(
            device: device,
            surface: surface,
            backgroundColor: backgroundColor,
            contentMode: contentMode
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.isOpaque = true
        layer?.backgroundColor = backgroundColor.cgColor

        metalView.delegate = renderer
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = true
        metalView.colorPixelFormat = CanvasIOSurfacePreviewRenderer.colorPixelFormat
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        metalView.layer?.isOpaque = true
        metalView.layer?.backgroundColor = backgroundColor.cgColor

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

    public func update(
        surface: IOSurfaceRef?,
        backgroundColor: NSColor,
        contentMode: CanvasIOSurfacePreview.ContentMode,
        preferredFramesPerSecond: Int
    ) {
        renderer.update(surface: surface, backgroundColor: backgroundColor, contentMode: contentMode)
        layer?.backgroundColor = backgroundColor.cgColor
        metalView.layer?.backgroundColor = backgroundColor.cgColor
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
    }
}

private final class CanvasIOSurfacePreviewRenderer: NSObject, MTKViewDelegate {
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private var surface: IOSurfaceRef?
    private var cachedTexture: MTLTexture?
    private var cachedSurfaceID: IOSurfaceID = 0
    private var cachedWidth = 0
    private var cachedHeight = 0
    private let stateLock = NSLock()
    private var state: State

    private struct State {
        var surface: IOSurfaceRef?
        var backgroundColor: NSColor
        var contentMode: CanvasIOSurfacePreview.ContentMode
    }

    init(
        device: MTLDevice?,
        surface: IOSurfaceRef?,
        backgroundColor: NSColor,
        contentMode: CanvasIOSurfacePreview.ContentMode
    ) {
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.pipelineState = Self.makePipelineState(device: device)
        self.state = State(surface: surface, backgroundColor: backgroundColor, contentMode: contentMode)
        super.init()
    }

    var clearColor: MTLClearColor {
        Self.clearColor(for: stateLock.withLock { state.backgroundColor })
    }

    func update(
        surface: IOSurfaceRef?,
        backgroundColor: NSColor,
        contentMode: CanvasIOSurfacePreview.ContentMode
    ) {
        stateLock.withLock {
            self.state = State(surface: surface, backgroundColor: backgroundColor, contentMode: contentMode)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let state = stateLock.withLock { self.state }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return
        }
        descriptor.colorAttachments[0].clearColor = Self.clearColor(for: state.backgroundColor)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        defer {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        guard let texture = texture(for: state.surface),
              let pipelineState else {
            return
        }

        let viewport = targetViewport(
            drawableSize: view.drawableSize,
            textureSize: CGSize(width: texture.width, height: texture.height),
            contentMode: state.contentMode
        )
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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

    private func texture(for surface: IOSurfaceRef?) -> MTLTexture? {
        guard let device,
              let surface else {
            cachedTexture = nil
            cachedSurfaceID = 0
            cachedWidth = 0
            cachedHeight = 0
            return nil
        }

        let surfaceID = IOSurfaceGetID(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }

        if cachedSurfaceID == surfaceID,
           cachedWidth == width,
           cachedHeight == height,
           let cachedTexture {
            return cachedTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            cachedTexture = nil
            cachedSurfaceID = 0
            cachedWidth = 0
            cachedHeight = 0
            return nil
        }

        cachedTexture = texture
        cachedSurfaceID = surfaceID
        cachedWidth = width
        cachedHeight = height
        return texture
    }

    private func targetViewport(
        drawableSize: CGSize,
        textureSize: CGSize,
        contentMode: CanvasIOSurfacePreview.ContentMode
    ) -> MTLViewport {
        let drawableWidth = max(1, drawableSize.width)
        let drawableHeight = max(1, drawableSize.height)
        let textureWidth = max(1, textureSize.width)
        let textureHeight = max(1, textureSize.height)
        let scale: CGFloat
        switch contentMode {
        case .fit:
            scale = min(drawableWidth / textureWidth, drawableHeight / textureHeight)
        case .fill:
            scale = max(drawableWidth / textureWidth, drawableHeight / textureHeight)
        }
        let width = textureWidth * scale
        let height = textureHeight * scale
        return MTLViewport(
            originX: Double((drawableWidth - width) / 2),
            originY: Double((drawableHeight - height) / 2),
            width: Double(width),
            height: Double(height),
            znear: 0,
            zfar: 1
        )
    }

    private static func makePipelineState(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut canvas_iosurface_vertex(uint vertexID [[vertex_id]]) {
            constexpr float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            constexpr float2 coords[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = coords[vertexID];
            return out;
        }

        fragment float4 canvas_iosurface_fragment(
            VertexOut in [[stage_in]],
            texture2d<float> surfaceTexture [[texture(0)]]
        ) {
            constexpr sampler surfaceSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            return surfaceTexture.sample(surfaceSampler, in.texCoord);
        }
        """

        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertexFunction = library.makeFunction(name: "canvas_iosurface_vertex"),
              let fragmentFunction = library.makeFunction(name: "canvas_iosurface_fragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.pixelFormat = colorPixelFormat
        colorAttachment?.isBlendingEnabled = true
        colorAttachment?.sourceRGBBlendFactor = .one
        colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.rgbBlendOperation = .add
        colorAttachment?.sourceAlphaBlendFactor = .one
        colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.alphaBlendOperation = .add
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
#endif
