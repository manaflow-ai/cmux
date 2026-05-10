import AppKit
import CoreGraphics
import SwiftUI

struct WindowDetailView: View {
    let window: HostWindow?
    let liveFrame: CGImage?
    let isLiveCaptureRunning: Bool
    let permissions: PermissionState
    let status: StatusBanner?
    let onRefreshWindows: () -> Void
    let onRestartLiveCapture: () -> Void
    let onRequestAccessibility: () -> Void
    let onRequestScreenCapture: () -> Void
    let onRelaunchApp: () -> Void
    let onRaise: () -> Void
    let onPlace: (WindowPlacement) -> Void
    let onMouseInput: (WindowMouseInput) -> Void
    let onScrollInput: (WindowScrollInput) -> Void
    let onKeyInput: (WindowKeyInput) -> Void

    @SceneStorage("desktopPrototype.previewHeight") private var previewHeight = 760.0

    var body: some View {
        if let window {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderView(window: window, onRefreshWindows: onRefreshWindows, onRestartLiveCapture: onRestartLiveCapture)

                    if let status {
                        StatusBannerView(status: status)
                    }

                    LivePreviewView(
                        image: liveFrame,
                        window: window,
                        isRunning: isLiveCaptureRunning,
                        previewHeight: $previewHeight,
                        onMouseInput: onMouseInput,
                        onScrollInput: onScrollInput,
                        onKeyInput: onKeyInput
                    )

                    PermissionsView(
                        permissions: permissions,
                        onRequestAccessibility: onRequestAccessibility,
                        onRequestScreenCapture: onRequestScreenCapture,
                        onRelaunchApp: onRelaunchApp
                    )

                    ActionsView(onRaise: onRaise, onPlace: onPlace)

                    WindowMetadataView(window: window)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView(
                String(localized: "detail.empty.title", defaultValue: "Select a window", bundle: .module),
                systemImage: "macwindow"
            )
        }
    }
}

private struct HeaderView: View {
    let window: HostWindow
    let onRefreshWindows: () -> Void
    let onRestartLiveCapture: () -> Void

    private var title: String {
        window.hasTitle
            ? window.title
            : String(localized: "window.untitled", defaultValue: "Untitled", bundle: .module)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(window.ownerName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRestartLiveCapture) {
                Label(
                    String(localized: "button.restartStream", defaultValue: "Restart Stream", bundle: .module),
                    systemImage: "video.badge.arrow.down.left"
                )
            }

            Button(action: onRefreshWindows) {
                Label(
                    String(localized: "button.refresh", defaultValue: "Refresh", bundle: .module),
                    systemImage: "arrow.clockwise"
                )
            }
        }
    }
}

private struct LivePreviewView: View {
    let image: CGImage?
    let window: HostWindow
    let isRunning: Bool
    @Binding var previewHeight: Double
    let onMouseInput: (WindowMouseInput) -> Void
    let onScrollInput: (WindowScrollInput) -> Void
    let onKeyInput: (WindowKeyInput) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(localized: "section.livePreview", defaultValue: "Live Preview", bundle: .module))
                    .font(.headline)
                Image(systemName: isRunning ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(isRunning ? .red : .secondary)
                Spacer()
                Label(
                    String(localized: "preview.size", defaultValue: "Preview Size", bundle: .module),
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
                .foregroundStyle(.secondary)
                Slider(value: $previewHeight, in: 420...1400)
                    .frame(width: 260)
            }
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image {
                    InteractiveWindowPreview(
                        image: image,
                        window: window,
                        onMouse: onMouseInput,
                        onScroll: onScrollInput,
                        onKey: onKeyInput
                    )
                    .padding(12)
                } else {
                    ContentUnavailableView(
                        String(localized: "detail.livePreview.waiting", defaultValue: "Waiting for live video", bundle: .module),
                        systemImage: "video.slash"
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: previewHeight)
        }
    }
}

private struct PermissionsView: View {
    let permissions: PermissionState
    let onRequestAccessibility: () -> Void
    let onRequestScreenCapture: () -> Void
    let onRelaunchApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "section.permissions", defaultValue: "Permissions", bundle: .module))
                .font(.headline)

            HStack(spacing: 12) {
                PermissionStatusView(
                    title: String(localized: "permissions.accessibility", defaultValue: "Accessibility", bundle: .module),
                    isGranted: permissions.accessibilityTrusted,
                    actionTitle: String(localized: "button.request", defaultValue: "Request", bundle: .module),
                    action: onRequestAccessibility
                )

                PermissionStatusView(
                    title: String(localized: "permissions.screenCapture", defaultValue: "Screen Recording", bundle: .module),
                    isGranted: permissions.screenCaptureAllowed,
                    statusText: permissions.screenCaptureNeedsRestart
                        ? String(localized: "permission.restartRequired", defaultValue: "Restart Required", bundle: .module)
                        : nil,
                    actionTitle: permissions.screenCaptureNeedsRestart
                        ? String(localized: "button.relaunch", defaultValue: "Quit & Reopen", bundle: .module)
                        : String(localized: "button.request", defaultValue: "Request", bundle: .module),
                    action: permissions.screenCaptureNeedsRestart ? onRelaunchApp : onRequestScreenCapture
                )
            }
        }
    }
}

private struct PermissionStatusView: View {
    let title: String
    let isGranted: Bool
    var statusText: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(statusText ?? defaultStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var defaultStatusText: String {
        isGranted
            ? String(localized: "permission.granted", defaultValue: "Granted", bundle: .module)
            : String(localized: "permission.missing", defaultValue: "Missing", bundle: .module)
    }
}

private struct ActionsView: View {
    let onRaise: () -> Void
    let onPlace: (WindowPlacement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "section.actions", defaultValue: "Actions", bundle: .module))
                .font(.headline)

            HStack(spacing: 8) {
                Button(action: onRaise) {
                    Label(
                        String(localized: "button.raise", defaultValue: "Raise", bundle: .module),
                        systemImage: "arrow.up.forward.app"
                    )
                }

                Button {
                    onPlace(.center)
                } label: {
                    Label(
                        String(localized: "button.center", defaultValue: "Center", bundle: .module),
                        systemImage: "dot.scope"
                    )
                }

                Button {
                    onPlace(.leftHalf)
                } label: {
                    Label(
                        String(localized: "button.leftHalf", defaultValue: "Left", bundle: .module),
                        systemImage: "rectangle.lefthalf.filled"
                    )
                }

                Button {
                    onPlace(.rightHalf)
                } label: {
                    Label(
                        String(localized: "button.rightHalf", defaultValue: "Right", bundle: .module),
                        systemImage: "rectangle.righthalf.filled"
                    )
                }

                Button {
                    onPlace(.fill)
                } label: {
                    Label(
                        String(localized: "button.fill", defaultValue: "Fill", bundle: .module),
                        systemImage: "arrow.up.left.and.arrow.down.right"
                    )
                }
            }
        }
    }
}

private struct WindowMetadataView: View {
    let window: HostWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "section.details", defaultValue: "Details", bundle: .module))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                MetadataRow(
                    title: String(localized: "detail.owner", defaultValue: "Owner", bundle: .module),
                    value: window.ownerName
                )
                MetadataRow(
                    title: String(localized: "detail.pid", defaultValue: "PID", bundle: .module),
                    value: String(window.ownerPID)
                )
                MetadataRow(
                    title: String(localized: "detail.windowID", defaultValue: "Window ID", bundle: .module),
                    value: String(window.id)
                )
                MetadataRow(
                    title: String(localized: "detail.frame", defaultValue: "Frame", bundle: .module),
                    value: frameString(window.frame)
                )
                MetadataRow(
                    title: String(localized: "detail.location", defaultValue: "Location", bundle: .module),
                    value: window.isOnScreen
                        ? String(localized: "window.location.currentDesktop", defaultValue: "Current Desktop", bundle: .module)
                        : String(localized: "window.location.otherDesktop", defaultValue: "Other Desktop", bundle: .module)
                )
                MetadataRow(
                    title: String(localized: "detail.layer", defaultValue: "Layer", bundle: .module),
                    value: String(window.layer)
                )
                MetadataRow(
                    title: String(localized: "detail.alpha", defaultValue: "Alpha", bundle: .module),
                    value: String(format: "%.2f", window.alpha)
                )
            }
            .font(.callout)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func frameString(_ frame: CGRect) -> String {
        let format = String(localized: "window.frame.full", defaultValue: "x %.0f, y %.0f, %.0f x %.0f", bundle: .module)
        return String(format: format, frame.minX, frame.minY, frame.width, frame.height)
    }
}

private struct MetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
        }
    }
}

private struct StatusBannerView: View {
    let status: StatusBanner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
            Text(status.message)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var color: Color {
        switch status.kind {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var symbolName: String {
        switch status.kind {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}
