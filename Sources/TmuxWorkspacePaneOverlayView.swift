import AppKit
import CmuxFoundation
import SwiftUI

struct TmuxWorkspacePaneOverlayView: View {
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let activePaneBorderRect: CGRect?
    let activePaneBorderColorHex: String?
    let focusMarkerDimRects: [CGRect]
    let focusMarkerStyle: String
    let focusMarkerColorHex: String?
    let focusMarkerRect: CGRect?
    let focusMarkerVisibility: String
    let focusMarkerPulseStartedAt: Date?
    let focusMarkerThickness: Double
    let focusMarkerIntensity: Double
    let flashStartedAt: Date?
    let flashReason: WorkspaceAttentionFlashReason?
    let workspaceAttentionColor: WorkspaceAttentionColor
    @State private var completedFlashStartedAt: Date?
    @State private var completedFocusMarkerPulseStartedAt: Date?

    var body: some View {
        let attentionColor = Color(nsColor: workspaceAttentionColor.nsColor)
        overlayContent(attentionColor: attentionColor)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func overlayContent(attentionColor: Color) -> some View {
        if shouldAnimateFlash || shouldAnimateFocusMarkerPulse,
           let startDate = animationStartDate {
            TimelineView(TmuxWorkspacePaneFlashTimelineSchedule(
                startDate: startDate,
                duration: animationDuration
            )) { timeline in
                overlayCanvas(timelineDate: timeline.date, attentionColor: attentionColor)
                    .onChange(of: timeline.date) { _, date in
                        if let flashStartedAt,
                           date.timeIntervalSince(flashStartedAt) >= FocusFlashPattern.duration {
                            completedFlashStartedAt = flashStartedAt
                        }
                        if let pulseStartedAt = focusMarkerPulseStartedAt,
                           date.timeIntervalSince(pulseStartedAt) >= FocusMarkerPulse.duration {
                            completedFocusMarkerPulseStartedAt = pulseStartedAt
                        }
                    }
            }
        } else if !unreadRects.isEmpty || activePaneBorderRect != nil || focusMarkerStyle != "none" {
            overlayCanvas(timelineDate: nil, attentionColor: attentionColor)
        } else {
            Color.clear
        }
    }

    private var shouldAnimateFlash: Bool {
        guard let flashRect,
              let flashStartedAt else { return false }
        guard completedFlashStartedAt != flashStartedAt,
              ringPath(for: flashRect) != nil else { return false }
        return Date() <= flashStartedAt.addingTimeInterval(FocusFlashPattern.duration)
    }

    private var shouldAnimateFocusMarkerPulse: Bool {
        guard focusMarkerStyle != "none",
              let started = focusMarkerPulseStartedAt,
              completedFocusMarkerPulseStartedAt != started else { return false }
        return Date() <= started.addingTimeInterval(FocusMarkerPulse.duration)
    }

    private var animationStartDate: Date? {
        [shouldAnimateFlash ? flashStartedAt : nil, shouldAnimateFocusMarkerPulse ? focusMarkerPulseStartedAt : nil]
            .compactMap { $0 }
            .min()
    }

    private var animationDuration: TimeInterval {
        guard let start = animationStartDate else { return 0 }
        let flashEnd = shouldAnimateFlash ? flashStartedAt?.addingTimeInterval(FocusFlashPattern.duration) : nil
        let markerEnd = shouldAnimateFocusMarkerPulse ? focusMarkerPulseStartedAt?.addingTimeInterval(FocusMarkerPulse.duration) : nil
        return [flashEnd, markerEnd].compactMap { $0 }.map { $0.timeIntervalSince(start) }.max() ?? 0
    }

    /// Clips the active border to the drawable canvas so its bottom and right
    /// strokes remain visible when the zoom container reaches a window edge.
    private func overlayCanvas(timelineDate: Date?, attentionColor: Color) -> some View {
        Canvas { context, size in
            if let activePaneBorderRect,
               let activePaneBorderColorHex {
                drawActivePaneBorder(
                    in: &context,
                    rect: activePaneBorderRect.intersection(CGRect(origin: .zero, size: size)),
                    colorHex: activePaneBorderColorHex
                )
            }

            let markerOpacity: Double = {
                let baseline = focusMarkerVisibility == "persistent" ? 1.0 : 0.0
                guard let timelineDate, let started = focusMarkerPulseStartedAt else { return baseline }
                let pulse = FocusMarkerPulse.opacity(at: timelineDate.timeIntervalSince(started))
                return baseline + pulse
            }()
            if focusMarkerStyle == "dim-others", let markerColor = resolvedFocusMarkerColor {
                for rect in focusMarkerDimRects {
                    let clipped = rect.intersection(CGRect(origin: .zero, size: size))
                    context.fill(Path(clipped), with: .color(markerColor.opacity(min(0.8, focusMarkerIntensity * markerOpacity))))
                }
            } else if focusMarkerStyle != "none", let focusMarkerRect,
                      let markerColor = resolvedFocusMarkerColor {
                drawFocusMarker(
                    in: &context,
                    rect: focusMarkerRect.intersection(CGRect(origin: .zero, size: size)),
                    color: markerColor,
                    opacity: markerOpacity,
                    style: focusMarkerStyle
                )
            }

            for rect in unreadRects {
                drawUnreadRing(in: &context, rect: rect, color: attentionColor)
            }

            guard let flashRect,
                  let flashStartedAt,
                  let timelineDate else { return }
            let elapsed = timelineDate.timeIntervalSince(flashStartedAt)
            let opacity = FocusFlashPattern.opacity(at: elapsed)
            guard opacity > 0.001 else { return }
            drawFlashRing(
                in: &context,
                rect: flashRect,
                opacity: opacity,
                reason: flashReason ?? .notificationArrival,
                color: attentionColor
            )
        }
    }

    private var resolvedFocusMarkerColor: Color? {
        guard let focusMarkerColorHex,
              let color = NSColor(hex: focusMarkerColorHex) else { return nil }
        return Color(nsColor: color)
    }

    private func drawFocusMarker(
        in context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        opacity: Double,
        style: String
    ) {
        let innerRect = rect.insetBy(dx: 8, dy: 8)
        guard innerRect.width > 0, innerRect.height > 0 else { return }
        let path: Path
        if style == "edge" {
            // An inset top edge leaves the blue unread outline unobscured.
            path = Path { path in
                path.move(to: CGPoint(x: innerRect.minX, y: innerRect.minY))
                path.addLine(to: CGPoint(x: innerRect.maxX, y: innerRect.minY))
            }
        } else {
            path = Path(roundedRect: innerRect, cornerRadius: 4)
        }
        var markerContext = context
        if style == "glow" {
            markerContext.addFilter(.shadow(color: color.opacity(min(0.8, opacity * focusMarkerIntensity)), radius: focusMarkerThickness * 2))
        }
        markerContext.stroke(
            path,
            with: .color(color.opacity(min(0.8, opacity * focusMarkerIntensity))),
            style: StrokeStyle(lineWidth: focusMarkerThickness, lineJoin: .round)
        )
    }

    private func drawActivePaneBorder(
        in context: inout GraphicsContext,
        rect: CGRect,
        colorHex: String
    ) {
        guard let path = ringPath(for: rect),
              let color = NSColor(hex: colorHex) else { return }
        context.stroke(
            path,
            with: .color(Color(nsColor: color)),
            style: StrokeStyle(
                lineWidth: PanelOverlayRingMetrics.lineWidth,
                lineJoin: .round
            )
        )
    }

    private func drawUnreadRing(in context: inout GraphicsContext, rect: CGRect, color: Color) {
        guard let path = ringPath(for: rect) else { return }
        let presentation = WorkspaceAttentionCoordinator.notificationRingStyle

        var glowContext = context
        glowContext.addFilter(
            .shadow(
                color: color.opacity(presentation.glowOpacity),
                radius: presentation.glowRadius
            )
        )
        glowContext.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: PanelOverlayRingMetrics.lineWidth, lineJoin: .round)
        )
    }

    private func drawFlashRing(
        in context: inout GraphicsContext,
        rect: CGRect,
        opacity: Double,
        reason: WorkspaceAttentionFlashReason,
        color: Color
    ) {
        guard let path = ringPath(for: rect) else { return }
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)

        var glowContext = context
        glowContext.addFilter(
            .shadow(
                color: color.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
        )
        glowContext.stroke(
            path,
            with: .color(color.opacity(opacity)),
            style: StrokeStyle(lineWidth: PanelOverlayRingMetrics.lineWidth, lineJoin: .round)
        )
    }

    private func ringPath(for rect: CGRect) -> Path? {
        guard rect.width > PanelOverlayRingMetrics.inset * 2,
              rect.height > PanelOverlayRingMetrics.inset * 2 else { return nil }
        return Path(
            roundedRect: PanelOverlayRingMetrics.pathRect(in: rect),
            cornerRadius: PanelOverlayRingMetrics.cornerRadius
        )
    }
}

private enum FocusMarkerPulse {
    static let duration: TimeInterval = 0.6

    static func opacity(at elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }
        if elapsed <= 0.18 {
            let progress = elapsed / 0.18
            return 1 - ((1 - progress) * (1 - progress))
        }
        let progress = min(1, (elapsed - 0.18) / (duration - 0.18))
        return 1 - (progress * progress)
    }
}

struct TmuxWorkspacePaneFlashTimelineSchedule: TimelineSchedule {
    let startDate: Date
    let duration: TimeInterval

    init(startDate: Date, duration: TimeInterval = FocusFlashPattern.duration) {
        self.startDate = startDate
        self.duration = duration
    }

    func entries(from requestedStartDate: Date, mode: Mode) -> Entries {
        let firstDate = requestedStartDate > startDate ? requestedStartDate : startDate
        let interval = mode == .lowFrequency ? 1.0 / 10.0 : 1.0 / 60.0
        return Entries(
            nextDate: firstDate,
            endDate: startDate.addingTimeInterval(duration),
            interval: interval
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date
        let endDate: Date
        let interval: TimeInterval
        var finished = false

        mutating func next() -> Date? {
            guard !finished else { return nil }
            let date = min(nextDate, endDate)
            if date == endDate { finished = true }
            nextDate = nextDate.addingTimeInterval(interval)
            return date
        }
    }
}
