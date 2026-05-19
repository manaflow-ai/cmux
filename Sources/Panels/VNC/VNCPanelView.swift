import CMUXVNC
import Metal
import QuartzCore
import SwiftUI

struct VNCPanelView: View {
    @ObservedObject var panel: VNCPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VNCMetalCanvasRepresentable(panel: panel)
                .overlay {
                    if panel.latestFrame == nil {
                        Text(VNCPanelText.noFrame)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onRequestPanelFocus()
                    panel.focus()
                }
        }
        .background(Color(nsColor: appearance.backgroundColor))
        .task(id: panel.id) {
            panel.startIfNeeded()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            panel.setVisible(visible)
        }
        .onAppear {
            panel.setVisible(isVisibleInUI)
        }
        .onDisappear {
            panel.setVisible(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(panel.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                panel.reconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(VNCPanelText.reconnect)
            .accessibilityLabel(VNCPanelText.reconnect)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: appearance.backgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 1)
        }
    }

    private var statusText: String {
        switch panel.connectionState {
        case .idle:
            return VNCPanelText.stateIdle
        case .connecting:
            return VNCPanelText.stateConnecting
        case .connected:
            return VNCPanelText.stateConnected
        case .disconnected:
            return VNCPanelText.stateDisconnected
        case .failed:
            return VNCPanelText.stateFailed
        }
    }

    private var statusColor: Color {
        switch panel.connectionState {
        case .connected:
            return .green
        case .connecting, .idle:
            return .secondary
        case .disconnected, .failed:
            return .red
        }
    }
}

private struct VNCMetalCanvasRepresentable: NSViewRepresentable {
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

private final class VNCMetalCanvasView: NSView {
    var onText: ((String) -> Void)?
    var onPointer: ((Int, Int, Int, Bool) -> Void)?

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
        guard lastSequence != frame.header.sequence else { return }
        lastSequence = frame.header.sequence
        resizeFramebufferIfNeeded(width: frame.header.framebufferWidth, height: frame.header.framebufferHeight)
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

    private func resizeFramebufferIfNeeded(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if width == framebufferWidth, height == framebufferHeight { return }
        framebufferWidth = width
        framebufferHeight = height
        framebuffer = Data(repeating: 0, count: width * height * 4)
        metalLayer.drawableSize = CGSize(width: width, height: height)
    }

    private func copy(_ frame: VNCDisplayFrame) {
        let header = frame.header
        guard header.pixelFormat == .bgra8,
              header.framebufferWidth == framebufferWidth,
              header.framebufferHeight == framebufferHeight,
              framebuffer.count == framebufferWidth * framebufferHeight * 4 else {
            return
        }

        frame.payload.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            framebuffer.withUnsafeMutableBytes { destinationBytes in
                guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                let rowBytes = header.width * 4
                for row in 0..<header.height {
                    let sourceOffset = row * rowBytes
                    let destinationOffset = ((header.y + row) * framebufferWidth + header.x) * 4
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
                bytesPerRow: framebufferWidth * 4
            )
        }
        let commandBuffer = commandQueue?.makeCommandBuffer()
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }

    private func sendPointer(_ event: NSEvent, button: Int, isDown: Bool) {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let normalizedX = max(0, min(1, point.x / max(bounds.width, 1)))
        let normalizedY = max(0, min(1, (bounds.height - point.y) / max(bounds.height, 1)))
        let remoteX = Int((normalizedX * CGFloat(framebufferWidth - 1)).rounded())
        let remoteY = Int((normalizedY * CGFloat(framebufferHeight - 1)).rounded())
        onPointer?(remoteX, remoteY, button, isDown)
    }
}
