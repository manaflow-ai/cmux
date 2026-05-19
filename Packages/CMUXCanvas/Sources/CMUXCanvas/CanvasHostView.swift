#if canImport(AppKit) && canImport(MetalKit) && canImport(SwiftUI)
import AppKit
import CMUXLayout
import MetalKit
import SwiftUI

public final class CanvasHostView: NSView {
    private let metalView: MTKView
    private let renderer: CanvasMetalRenderer
    private var scene: CanvasScene

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()
        self.metalView = MTKView(frame: .zero, device: device)
        self.renderer = CanvasMetalRenderer(
            backgroundColor: backgroundColor,
            scene: scene,
            device: device
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.isOpaque = true

        metalView.delegate = renderer
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = true
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
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
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        renderer.update(scene: scene, backgroundColor: backgroundColor)
        metalView.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        metalView.clearColor = renderer.clearColor
        metalView.setNeedsDisplay(metalView.bounds)
    }
}

public struct CanvasHostRepresentable: NSViewRepresentable {
    public var scene: CanvasScene
    public var backgroundColor: NSColor
    public var preferredFramesPerSecond: Int

    public init(
        scene: CanvasScene = CanvasScene(),
        backgroundColor: NSColor,
        preferredFramesPerSecond: Int = 120
    ) {
        self.scene = scene
        self.backgroundColor = backgroundColor
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(
            scene: scene,
            backgroundColor: backgroundColor,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: scene,
            backgroundColor: backgroundColor,
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
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {
        nsView.update(
            scene: CanvasScene(viewportSize: nsView.bounds.size),
            backgroundColor: backgroundColor,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }
}

private final class CanvasMetalRenderer: NSObject, MTKViewDelegate {
    private var backgroundColor: NSColor
    private var scene: CanvasScene
    private let commandQueue: MTLCommandQueue?
    private var scheduler = CanvasFrameScheduler()

    init(backgroundColor: NSColor, scene: CanvasScene, device: MTLDevice?) {
        self.backgroundColor = backgroundColor
        self.scene = scene
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

    func update(scene: CanvasScene, backgroundColor: NSColor) {
        self.scene = scene
        self.backgroundColor = backgroundColor
        scheduler.markNeedsRender()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene = CanvasScene(
            viewport: scene.viewport,
            viewportSize: size,
            scale: scene.scale,
            padding: scene.padding,
            grid: scene.grid,
            surfaces: scene.surfaces,
            alignmentGuides: scene.alignmentGuides
        )
        scheduler.markNeedsRender()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        _ = scheduler.consumeFrame()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif
