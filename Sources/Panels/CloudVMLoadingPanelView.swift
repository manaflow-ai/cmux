import SwiftUI
import CmuxAppKitSupportUI
import CmuxFeedback

struct CloudVMLoadingPanelView: View {
    @ObservedObject var panel: CloudVMLoadingPanel

    var body: some View {
        TimelineView(.periodic(from: panel.startedAt, by: 1)) { context in
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(panel.startedAt).rounded(.down)))
            if let operation = MachineCreateCoordinator.shared.operations.first(where: { $0.request.reservedWorkspaceID == panel.workspaceId }) {
                MachineCreateLoadingContent(
                    operation: operation,
                    actions: .bound(coordinator: .shared),
                    elapsedSeconds: max(0, Int(context.date.timeIntervalSince(operation.startedAt).rounded(.down)))
                )
            } else if panel.isLoading {
                // Base opens already reserve the destination workspace and the
                // Machines panel owns the optimistic progress state. Keep this
                // pane visually quiet until the real Cloud terminal adopts it;
                // the old full-pane “Opening Cloud VM” card made an optimistic
                // workspace look blocked and duplicated the sidebar status.
                Color(nsColor: GhosttyApp.shared.defaultBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                baseContent(elapsedSeconds: elapsedSeconds)
            }
        }
    }

    private func baseContent(elapsedSeconds: Int) -> some View {
            // Match semantic text colors to the terminal background, which can
            // differ from the system appearance.
            let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
            let readableScheme = WindowChromeColorResolver().readableColorScheme(for: backgroundColor)
            return VStack(spacing: 14) {
                switch panel.phase {
                case .loading(let loadingHeadline):
                    if let loadingHeadline {
                        ProgressView()
                            .controlSize(.small)
                        Text(loadingHeadline)
                            .cmuxFont(size: 14, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text(String(format: String(
                            localized: "panel.cloudVM.loading.elapsed",
                            defaultValue: "%ds elapsed"
                        ), elapsedSeconds))
                        .cmuxFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "panel.cloudVM.loading.headline", defaultValue: "Opening Base"))
                            .cmuxFont(size: 14, weight: .semibold)
                            .foregroundStyle(.primary)
                        CloudVMLoadingStatusView(elapsedSeconds: elapsedSeconds)
                    }
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
            .background(Color(nsColor: backgroundColor))
            .environment(\.colorScheme, readableScheme)
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
