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
        view.onKey = { [weak panel] keyCode, isDown in
            panel?.sendKey(keyCode: keyCode, isDown: isDown)
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
        view.onKey = { [weak panel] keyCode, isDown in
            panel?.sendKey(keyCode: keyCode, isDown: isDown)
        }
        view.onPointer = { [weak panel] x, y, button, isDown in
            panel?.sendPointer(x: x, y: y, button: button, isDown: isDown)
        }
        if let frame = panel.latestFrame {
            view.apply(frame)
        } else {
            view.resetFrameSequence()
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
    var onKey: ((UInt16, Bool) -> Void)?
    var onPointer: ((Int, Int, Int?, Bool?) -> Void)?

    private static let maxFramebufferDimension = 16_384
    private static let maxFramebufferPixels = 33_554_432
    private static let bytesPerPixel = 4

    private let device = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private let rootLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private var framebuffer = Data()
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var lastSequence: UInt64?
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        layer = rootLayer
        rootLayer.addSublayer(metalLayer)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsGravity = .resize
        metalLayer.masksToBounds = true
        commandQueue = device?.makeCommandQueue()
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalLayerGeometry()
        drawFramebuffer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rootLayer.frame = bounds
        updateMetalLayerGeometry()
        drawFramebuffer()
    }

    func close() {
        onText = nil
        onKey = nil
        onPointer = nil
        framebuffer.removeAll(keepingCapacity: false)
        removePointerTrackingArea()
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

    func resetFrameSequence() {
        lastSequence = nil
    }

    override func keyDown(with event: NSEvent) {
        if isDirectKeyEvent(event) {
            onKey?(event.keyCode, true)
            return
        }
        if let text = remoteText(for: event) {
            onText?(text)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if isDirectKeyEvent(event) {
            onKey?(event.keyCode, false)
            return
        }
        super.keyUp(with: event)
    }

    override func insertText(_ insertString: Any) {
        let text: String
        if let value = insertString as? NSAttributedString {
            text = value.string
        } else if let value = insertString as? String {
            text = value
        } else {
            text = String(describing: insertString)
        }
        guard !text.isEmpty else { return }
        onText?(text)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            onText?("\n")
        case #selector(insertTab(_:)):
            onText?("\t")
        case #selector(deleteBackward(_:)):
            onText?("\u{7f}")
        case #selector(cancelOperation(_:)):
            onKey?(53, true)
            onKey?(53, false)
        default:
            super.doCommand(by: selector)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isModifierKeyCode(event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        onKey?(event.keyCode, modifierIsDown(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, button: 0, isDown: true)
    }

    override func mouseEntered(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event, button: 0, isDown: true, clampOutside: true)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event, button: 0, isDown: false, clampOutside: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendPointer(event, button: 2, isDown: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(event, button: 2, isDown: true, clampOutside: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, button: 2, isDown: false, clampOutside: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removePointerTrackingArea()
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
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
        updateMetalLayerGeometry()
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

        _ = VNCFrameBlitter.copyBGRAFrame(
            header: header,
            payload: frame.payload,
            into: &framebuffer,
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight
        )
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

    private func updateMetalLayerGeometry() {
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.frame = aspectFittedFramebufferRect()
        if framebufferWidth > 0, framebufferHeight > 0 {
            metalLayer.drawableSize = CGSize(width: framebufferWidth, height: framebufferHeight)
        } else {
            let scale = metalLayer.contentsScale
            metalLayer.drawableSize = CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            )
        }
    }

    private func removePointerTrackingArea() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
            self.pointerTrackingArea = nil
        }
    }

    private func sendPointerMove(_ event: NSEvent) {
        sendPointer(event, button: nil, isDown: nil)
    }

    private func sendPointer(_ event: NSEvent, button: Int?, isDown: Bool?, clampOutside: Bool = false) {
        guard let remotePoint = remotePointerPoint(for: event, clampOutside: clampOutside) else { return }
        onPointer?(remotePoint.x, remotePoint.y, button, isDown)
    }

    private func isDirectKeyEvent(_ event: NSEvent) -> Bool {
        isSpecialKeyCode(event.keyCode)
    }

    private func remoteText(for event: NSEvent) -> String? {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.charactersIgnoringModifiers,
           !text.isEmpty {
            return text
        }
        guard let text = event.characters, !text.isEmpty else { return nil }
        return text
    }

    private func isSpecialKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 48, 51, 53, 71, 76, 96...111, 114...126:
            return true
        default:
            return false
        }
    }

    private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62:
            return true
        default:
            return false
        }
    }

    private func modifierIsDown(for event: NSEvent) -> Bool {
        switch event.keyCode {
        case 54, 55:
            return event.modifierFlags.contains(.command)
        case 56, 60:
            return event.modifierFlags.contains(.shift)
        case 58, 61:
            return event.modifierFlags.contains(.option)
        case 59, 62:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func remotePointerPoint(for event: NSEvent, clampOutside: Bool) -> (x: Int, y: Int)? {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let drawRect = aspectFittedFramebufferRect()
        guard drawRect.width > 0, drawRect.height > 0 else {
            return nil
        }
        if !clampOutside, !drawRect.contains(point) {
            return nil
        }
        let clampedPoint = CGPoint(
            x: max(drawRect.minX, min(drawRect.maxX, point.x)),
            y: max(drawRect.minY, min(drawRect.maxY, point.y))
        )
        let normalizedX = max(0, min(1, (clampedPoint.x - drawRect.minX) / drawRect.width))
        let normalizedY = max(0, min(1, (drawRect.maxY - clampedPoint.y) / drawRect.height))
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
