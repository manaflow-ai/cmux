import SwiftUI

struct ApplicationPanelView: View {
    let panel: ApplicationPanel
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if let target = panel.captureTarget {
                VStack(spacing: 0) {
                    captureToolbar
                    Divider()
                    captureView(target: target)
                }
            } else {
                ApplicationSurfacePickerView(
                    model: panel.pickerModel,
                    onRefresh: {
                        panel.refreshAvailableWindows()
                    },
                    onSetUpPermissions: {
                        AppDelegate.shared?.presentApplicationSurfacePermissions {
                            panel.retryWindowLoadingAfterPermissions()
                        }
                    },
                    onSelect: { window in
                        panel.selectWindow(window)
                    }
                )
                .onAppear {
                    panel.beginWindowSelectionIfNeeded()
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onRequestPanelFocus()
            }
        )
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(
            \.colorScheme,
            cmuxReadableColorScheme(for: appearance.backgroundColor)
        )
    }

    private var captureToolbar: some View {
        HStack(spacing: 8) {
            Label(panel.selectedWindowTitle, systemImage: "macwindow")
                .lineLimit(1)
            captureStatus
            Spacer(minLength: 8)
            Button {
                panel.chooseAnotherWindow()
            } label: {
                Label(
                    String(
                        localized: "panel.application.chooseAnother",
                        defaultValue: "Choose Another Window"
                    ),
                    systemImage: "rectangle.2.swap"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(
                String(
                    localized: "panel.application.chooseAnother",
                    defaultValue: "Choose Another Window"
                )
            )
            .accessibilityIdentifier("ApplicationSurfaceChooseAnother")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var captureStatus: some View {
        switch panel.captureState {
        case .starting:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text(
                    String(
                        localized: "panel.application.status.starting",
                        defaultValue: "Starting"
                    )
                )
            }
            .foregroundStyle(.secondary)
        case .streaming:
            Label(
                String(
                    localized: "panel.application.status.streaming",
                    defaultValue: "Live"
                ),
                systemImage: "circle.fill"
            )
            .foregroundStyle(.green)
        case .permissionRequired, .windowUnavailable, .failed:
            Label(
                String(
                    localized: "panel.application.status.needsAttention",
                    defaultValue: "Needs Attention"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private func captureView(
        target: ApplicationPanel.CaptureTarget
    ) -> some View {
        ApplicationCaptureRepresentable(
            panel: panel,
            windowID: target.windowID,
            processID: target.processID,
            isVisibleInUI: isVisibleInUI
        )
        .id(panel.captureGeneration)
        .overlay {
            captureStatusOverlay
        }
    }

    @ViewBuilder
    private var captureStatusOverlay: some View {
        switch panel.captureState {
        case .streaming:
            EmptyView()
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .permissionRequired:
            statusMessage(
                title: String(
                    localized: "panel.application.permissionRequired.title",
                    defaultValue: "Permissions required"
                ),
                detail: String(
                    localized: "panel.application.permissionRequired.detail",
                    defaultValue: "Allow Accessibility and Screen Recording for cmux Computer Use."
                ),
                primaryTitle: String(
                    localized: "panel.application.permissionRequired.action",
                    defaultValue: "Set Up Permissions"
                ),
                primaryAction: {
                    AppDelegate.shared?.presentApplicationSurfacePermissions {
                        panel.retryCaptureAfterPermissions()
                    }
                }
            )
        case .windowUnavailable:
            statusMessage(
                title: String(
                    localized: "panel.application.windowUnavailable.title",
                    defaultValue: "Application window unavailable"
                ),
                detail: String(
                    localized: "panel.application.windowUnavailable.detail",
                    defaultValue: "The application window is no longer available."
                ),
                primaryTitle: String(
                    localized: "panel.application.chooseAnother",
                    defaultValue: "Choose Another Window"
                ),
                primaryAction: {
                    panel.chooseAnotherWindow()
                }
            )
        case .failed:
            statusMessage(
                title: String(
                    localized: "panel.application.captureFailed.title",
                    defaultValue: "Application capture failed"
                ),
                detail: String(
                    localized: "panel.application.captureFailed.detail",
                    defaultValue: "cmux could not capture this window. Try again or choose another window."
                ),
                primaryTitle: String(
                    localized: "applicationSurface.picker.tryAgain",
                    defaultValue: "Try Again"
                ),
                primaryAction: {
                    panel.retryCaptureAfterPermissions()
                },
                secondaryTitle: String(
                    localized: "panel.application.chooseAnother",
                    defaultValue: "Choose Another Window"
                ),
                secondaryAction: {
                    panel.chooseAnotherWindow()
                }
            )
        }
    }

    private func statusMessage(
        title: String,
        detail: String,
        primaryTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 8) {
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .controlSize(.small)
                    }
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}
