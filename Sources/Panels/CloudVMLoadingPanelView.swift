import SwiftUI
import CmuxAppKitSupportUI
import CmuxFeedback

struct CloudVMLoadingPanelView: View {
    @ObservedObject var panel: CloudVMLoadingPanel

    var body: some View {
        let schedule: PeriodicTimelineSchedule = .periodic(from: panel.startedAt, by: 1)
        TimelineView(schedule) { context in
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(panel.startedAt).rounded(.down)))
            VStack(spacing: 14) {
                switch panel.phase {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "panel.cloudVM.loading.headline", defaultValue: "Opening Base"))
                        .cmuxFont(size: 14, weight: .semibold)
                        .foregroundStyle(.primary)
                    CloudVMLoadingStatusView(elapsedSeconds: elapsedSeconds)
                case .failed(let message, let failedElapsedSeconds):
                    CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18, tint: .orange)
                    Text(String(localized: "panel.cloudVM.loading.failed.headline", defaultValue: "Base unavailable"))
                        .cmuxFont(size: 14, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    HStack(spacing: 8) {
                        Button {
                            _ = AppDelegate.shared?.performCloudVMAction(debugSource: "panel.cloudVM.retry")
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.retry", defaultValue: "Retry"),
                                systemImage: "arrow.clockwise"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            FeedbackComposerBridge().openComposer()
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.feedback", defaultValue: "Send Feedback"),
                                systemImage: "bubble.left.and.text.bubble.right"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(String(format: String(
                        localized: "panel.cloudVM.loading.failed.elapsed",
                        defaultValue: "Waited %ds before stopping."
                    ), failedElapsedSeconds))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        }
    }
}

private struct CloudVMLoadingStatusView: View {
    let elapsedSeconds: Int

    var body: some View {
        VStack(spacing: 10) {
            Text(String(format: String(
                localized: "panel.cloudVM.loading.elapsed",
                defaultValue: "%ds elapsed"
            ), elapsedSeconds))
            .cmuxFont(size: 12, weight: .medium)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                CloudVMLoadingStatusRow(
                    icon: "checkmark.circle.fill",
                    text: String(localized: "panel.cloudVM.loading.step.workspace", defaultValue: "Pinned workspace created"),
                    isActive: false
                )
                CloudVMLoadingStatusRow(
                    icon: statusIcon(for: 0..<6),
                    text: statusText,
                    isActive: true
                )
                CloudVMLoadingStatusRow(
                    icon: elapsedSeconds >= 6 ? "arrow.triangle.2.circlepath" : "circle",
                    text: String(localized: "panel.cloudVM.loading.step.terminal", defaultValue: "Terminal will open automatically when ready"),
                    isActive: elapsedSeconds >= 6
                )
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var statusText: String {
        switch elapsedSeconds {
        case 0..<3:
            return String(localized: "panel.cloudVM.loading.step.request", defaultValue: "Requesting your persistent VM")
        case 3..<8:
            return String(localized: "panel.cloudVM.loading.step.resume", defaultValue: "Starting or resuming the VM")
        case 8..<18:
            return String(localized: "panel.cloudVM.loading.step.endpoint", defaultValue: "Waiting for a secure terminal endpoint")
        default:
            return String(localized: "panel.cloudVM.loading.step.retrying", defaultValue: "Still waiting; retrying in the background")
        }
    }

    private func statusIcon(for range: Range<Int>) -> String {
        range.contains(elapsedSeconds) ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
}

private struct CloudVMLoadingStatusRow: View {
    let icon: String
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: icon, pointSize: 12, tint: isActive ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 14)
            Text(text)
                .cmuxFont(size: 12)
                .foregroundStyle(isActive ? .secondary : .tertiary)
                .lineLimit(2)
        }
    }
}
