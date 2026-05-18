import SwiftUI

struct TmuxWorkspacePaneOverlayView: View {
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let flashStartedAt: Date?
    let flashReason: WorkspaceAttentionFlashReason?
    @State private var completedFlashStartedAt: Date?

    var body: some View {
        overlayContent
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var overlayContent: some View {
        if shouldAnimateFlash, let flashStartedAt {
            TimelineView(TmuxWorkspacePaneFlashTimelineSchedule(startDate: flashStartedAt)) { timeline in
                overlayCanvas(timelineDate: timeline.date)
                    .onChange(of: timeline.date) { _, date in
                        if date.timeIntervalSince(flashStartedAt) >= FocusFlashPattern.duration {
                            completedFlashStartedAt = flashStartedAt
                        }
                    }
            }
        } else if !unreadRects.isEmpty {
            overlayCanvas(timelineDate: nil)
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

    private func overlayCanvas(timelineDate: Date?) -> some View {
        Canvas { context, _ in
            for rect in unreadRects {
                drawUnreadRing(in: &context, rect: rect)
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
                reason: flashReason ?? .notificationArrival
            )
        }
    }

    private func drawUnreadRing(in context: inout GraphicsContext, rect: CGRect) {
        guard let path = ringPath(for: rect) else { return }
        var glowContext = context
        glowContext.addFilter(.shadow(color: Color.blue.opacity(0.35), radius: 3))
        glowContext.stroke(
            path,
            with: .color(Color.blue),
            style: StrokeStyle(lineWidth: PanelOverlayRingMetrics.lineWidth, lineJoin: .round)
        )
    }

    private func drawFlashRing(
        in context: inout GraphicsContext,
        rect: CGRect,
        opacity: Double,
        reason: WorkspaceAttentionFlashReason
    ) {
        guard let path = ringPath(for: rect) else { return }
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let strokeColor = Color(nsColor: presentation.accent.strokeColor)

        var glowContext = context
        glowContext.addFilter(
            .shadow(
                color: strokeColor.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
        )
        glowContext.stroke(
            path,
            with: .color(strokeColor.opacity(opacity)),
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

private struct TmuxWorkspacePaneFlashTimelineSchedule: TimelineSchedule {
    let startDate: Date

    func entries(from requestedStartDate: Date, mode: Mode) -> Entries {
        let firstDate = requestedStartDate > startDate ? requestedStartDate : startDate
        let interval = mode == .lowFrequency ? 1.0 / 10.0 : 1.0 / 60.0
        return Entries(
            nextDate: firstDate,
            endDate: startDate.addingTimeInterval(FocusFlashPattern.duration),
            interval: interval
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date
        let endDate: Date
        let interval: TimeInterval

        mutating func next() -> Date? {
            guard nextDate <= endDate else { return nil }
            let date = nextDate
            nextDate = nextDate.addingTimeInterval(interval)
            return date
        }
    }
}
