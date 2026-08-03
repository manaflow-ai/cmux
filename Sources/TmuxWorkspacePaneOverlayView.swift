import AppKit
import CmuxFoundation

/// Native, input-transparent pane attention overlay.
@MainActor
final class TmuxWorkspacePaneOverlayView: NSView {
    private var unreadRects: [CGRect] = []
    private var flashRect: CGRect?
    private var activePaneBorderRect: CGRect?
    private var activePaneBorderColorHex: String?
    private var flashStartedAt: Date?
    private var flashReason: WorkspaceAttentionFlashReason?
    private var animationTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect?,
        activePaneBorderColorHex: String?,
        flashStartedAt: Date?,
        flashReason: WorkspaceAttentionFlashReason?
    ) {
        self.unreadRects = unreadRects
        self.flashRect = flashRect
        self.activePaneBorderRect = activePaneBorderRect
        self.activePaneBorderColorHex = activePaneBorderColorHex
        self.flashStartedAt = flashStartedAt
        self.flashReason = flashReason
        restartAnimationIfNeeded()
        needsDisplay = true
    }

    func clear() {
        animationTask?.cancel()
        animationTask = nil
        unreadRects = []
        flashRect = nil
        activePaneBorderRect = nil
        activePaneBorderColorHex = nil
        flashStartedAt = nil
        flashReason = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let activePaneBorderRect,
           let colorHex = activePaneBorderColorHex,
           let color = NSColor(hex: colorHex) {
            stroke(
                rect: activePaneBorderRect,
                color: color,
                width: CGFloat(PaneChromeSettings.activeBorderLineWidth)
            )
        }

        let unreadStyle = WorkspaceAttentionCoordinator.notificationRingStyle
        for rect in unreadRects {
            stroke(
                rect: rect,
                color: unreadStyle.accent.strokeColor,
                width: PanelOverlayRingMetrics.lineWidth,
                glowOpacity: unreadStyle.glowOpacity,
                glowRadius: unreadStyle.glowRadius
            )
        }

        guard let flashRect,
              let flashStartedAt else { return }
        let opacity = FocusFlashPattern.opacity(at: Date().timeIntervalSince(flashStartedAt))
        guard opacity > 0.001 else { return }
        let style = WorkspaceAttentionCoordinator.flashStyle(for: flashReason ?? .notificationArrival)
        stroke(
            rect: flashRect,
            color: style.accent.strokeColor.withAlphaComponent(opacity),
            width: PanelOverlayRingMetrics.lineWidth,
            glowOpacity: opacity * style.glowOpacity,
            glowRadius: style.glowRadius
        )
    }

    private func stroke(
        rect: CGRect,
        color: NSColor,
        width: CGFloat,
        glowOpacity: Double = 0,
        glowRadius: CGFloat = 0
    ) {
        guard rect.width > PanelOverlayRingMetrics.inset * 2,
              rect.height > PanelOverlayRingMetrics.inset * 2 else { return }
        let path = NSBezierPath(
            roundedRect: PanelOverlayRingMetrics.pathRect(in: rect),
            xRadius: PanelOverlayRingMetrics.cornerRadius,
            yRadius: PanelOverlayRingMetrics.cornerRadius
        )
        path.lineWidth = width
        path.lineJoinStyle = .round
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if glowOpacity > 0 {
            context.setShadow(
                offset: .zero,
                blur: glowRadius,
                color: color.withAlphaComponent(glowOpacity).cgColor
            )
        }
        color.setStroke()
        path.stroke()
        context.restoreGState()
    }

    private func restartAnimationIfNeeded() {
        animationTask?.cancel()
        animationTask = nil
        guard let flashRect,
              let flashStartedAt,
              flashRect.width > PanelOverlayRingMetrics.inset * 2,
              flashRect.height > PanelOverlayRingMetrics.inset * 2,
              Date() <= flashStartedAt.addingTimeInterval(FocusFlashPattern.duration) else { return }
        animationTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self,
                      let startedAt = self.flashStartedAt,
                      Date().timeIntervalSince(startedAt) < FocusFlashPattern.duration else { return }
                self.needsDisplay = true
                try? await clock.sleep(for: .milliseconds(16))
            }
        }
    }

    deinit {
        animationTask?.cancel()
    }
}
