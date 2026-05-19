import AppKit
import CMUXVNC
import Metal
import QuartzCore
import SwiftUI

struct VNCMetalCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var panel: VNCPanel

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> VNCMetalCanvasView {
        let view = VNCMetalCanvasView()
        view.onText = { [weak panel] text in
            panel?.sendText(text)
        }
        view.onPointer = { [weak panel] x, y, button, isDown in
            panel?.sendPointer(x: x, y: y, button: button, isDown: isDown)
        }
        panel.attachFocusView(view)
        return view
    }

    func updateNSView(_ view: VNCMetalCanvasView, context: Context) {
        view.onText = { [weak panel] text in
            panel?.sendText(text)
        }
        view.onPointer = { [weak panel] x, y, button, isDown in
            panel?.sendPointer(x: x, y: y, button: button, isDown: isDown)
        }
        if let frame = panel.latestFrame {
            view.apply(frame)
        }
    }

    static func dismantleNSView(_ view: VNCMetalCanvasView, coordinator: Coordinator) {
        coordinator.panel?.attachFocusView(nil)
        view.close()
    }

    final class Coordinator {
        weak var panel: VNCPanel?

        init(panel: VNCPanel) {
            self.panel = panel
        }
    }
}

final class VNCMetalCanvasView: NSView {
    var onText: ((String) -> Void)?
    var onPointer: ((Int, Int, Int, Bool) -> Void)?

    private static let maxFramebufferDimension = 16_384
    private static let maxFramebufferPixels = 33_554_432
    private static let bytesPerPixel = 4

    private let device = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private let metalLayer = CAMetalLayer()
    private var framebuffer = Data()
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var lastSequence: UInt64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsGravity = .resizeAspect
        commandQueue = device?.makeCommandQueue()
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        drawFramebuffer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer.frame = bounds
        drawFramebuffer()
    }

    func close() {
        onText = nil
        onPointer = nil
        framebuffer.removeAll(keepingCapacity: false)
    }

    func apply(_ frame: VNCDisplayFrame) {
        guard lastSequence != frame.header.sequence,
              VNCFrameValidator.validate(header: frame.header, payloadByteCount: frame.payload.count) == nil,
              resizeFramebufferIfNeeded(width: frame.header.framebufferWidth, height: frame.header.framebufferHeight) else {
            return
        }
        lastSequence = frame.header.sequence
        copy(frame)
        drawFramebuffer()
    }

    override func keyDown(with event: NSEvent) {
        if let text = event.characters, !text.isEmpty {
            onText?(text)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        sendPointer(event, button: 0, isDown: true)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event, button: 0, isDown: true)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event, button: 0, isDown: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendPointer(event, button: 2, isDown: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, button: 2, isDown: false)
    }

    private func resizeFramebufferIfNeeded(width: Int, height: Int) -> Bool {
        guard let byteCount = Self.framebufferByteCount(width: width, height: height) else {
            return false
        }
        if width == framebufferWidth, height == framebufferHeight, framebuffer.count == byteCount {
            return true
        }
        framebufferWidth = width
        framebufferHeight = height
        framebuffer = Data(repeating: 0, count: byteCount)
        metalLayer.drawableSize = CGSize(width: width, height: height)
        return true
    }

    private func copy(_ frame: VNCDisplayFrame) {
        let header = frame.header
        guard header.pixelFormat == .bgra8,
              header.framebufferWidth == framebufferWidth,
              header.framebufferHeight == framebufferHeight,
              let expectedByteCount = Self.framebufferByteCount(width: framebufferWidth, height: framebufferHeight),
              framebuffer.count == expectedByteCount else {
            return
        }

        let rowBytes = header.width * Self.bytesPerPixel
        frame.payload.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            framebuffer.withUnsafeMutableBytes { destinationBytes in
                guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<header.height {
                    let sourceOffset = row * rowBytes
                    let destinationOffset = ((header.y + row) * framebufferWidth + header.x) * Self.bytesPerPixel
                    guard destinationOffset >= 0,
                          destinationOffset + rowBytes <= framebuffer.count,
                          sourceOffset >= 0,
                          sourceOffset + rowBytes <= frame.payload.count else {
                        return
                    }
                    destination.advanced(by: destinationOffset)
                        .update(from: source.advanced(by: sourceOffset), count: rowBytes)
                }
            }
        }
    }

    private func drawFramebuffer() {
        guard framebufferWidth > 0,
              framebufferHeight > 0,
              !framebuffer.isEmpty,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        framebuffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            drawable.texture.replace(
                region: MTLRegionMake2D(0, 0, framebufferWidth, framebufferHeight),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: framebufferWidth * Self.bytesPerPixel
            )
        }
        let commandBuffer = commandQueue?.makeCommandBuffer()
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }

    private func sendPointer(_ event: NSEvent, button: Int, isDown: Bool) {
        guard let remotePoint = remotePointerPoint(for: event) else { return }
        onPointer?(remotePoint.x, remotePoint.y, button, isDown)
    }

    private func remotePointerPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let drawRect = aspectFittedFramebufferRect()
        guard drawRect.width > 0, drawRect.height > 0, drawRect.contains(point) else {
            return nil
        }
        let normalizedX = max(0, min(1, (point.x - drawRect.minX) / drawRect.width))
        let normalizedY = max(0, min(1, (drawRect.maxY - point.y) / drawRect.height))
        return (
            Int((normalizedX * CGFloat(framebufferWidth - 1)).rounded()),
            Int((normalizedY * CGFloat(framebufferHeight - 1)).rounded())
        )
    }

    private func aspectFittedFramebufferRect() -> CGRect {
        guard framebufferWidth > 0,
              framebufferHeight > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return .zero
        }
        let contentSize = CGSize(width: framebufferWidth, height: framebufferHeight)
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func framebufferByteCount(width: Int, height: Int) -> Int? {
        guard width > 0,
              height > 0,
              width <= maxFramebufferDimension,
              height <= maxFramebufferDimension else {
            return nil
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixels <= maxFramebufferPixels else {
            return nil
        }
        let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteOverflow else { return nil }
        return byteCount
    }
}
