import AppKit
import CoreGraphics
import SwiftUI

struct WindowDetailView: View {
    let window: HostWindow?
    let liveFrame: CGImage?
    let isLiveCaptureRunning: Bool
    let isPaneSynced: Bool
    let permissions: PermissionState
    let status: StatusBanner?
    let onRefreshWindows: () -> Void
    let onRestartLiveCapture: () -> Void
    let onNativeSlotFrameChange: (NativeWindowSlotFrame) -> Void
    let onSyncPane: () -> Void
    let onDetachPane: () -> Void
    let onRequestAccessibility: () -> Void
    let onRequestScreenCapture: () -> Void
    let onRelaunchApp: () -> Void
    let onRaise: () -> Void
    let onPlace: (WindowPlacement) -> Void
    let onMouseInput: (WindowMouseInput) -> Void
    let onScrollInput: (WindowScrollInput) -> Void
    let onKeyInput: (WindowKeyInput) -> Void

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
                        isPaneSynced: isPaneSynced,
                        onNativeSlotFrameChange: onNativeSlotFrameChange,
                        onSyncPane: onSyncPane,
                        onDetachPane: onDetachPane,
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
    private let paneSpacing: CGFloat = 12
    private let workspaceHeight: CGFloat = 620

    let image: CGImage?
    let window: HostWindow
    let isRunning: Bool
    let isPaneSynced: Bool
    let onNativeSlotFrameChange: (NativeWindowSlotFrame) -> Void
    let onSyncPane: () -> Void
    let onDetachPane: () -> Void
    let onMouseInput: (WindowMouseInput) -> Void
    let onScrollInput: (WindowScrollInput) -> Void
    let onKeyInput: (WindowKeyInput) -> Void

    private var previewSize: CGSize {
        CGSize(
            width: max(window.frame.width, 1),
            height: max(window.frame.height, 1)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(localized: "section.workspace", defaultValue: "cmux Pane Prototype", bundle: .module))
                    .font(.headline)
                Image(systemName: isRunning ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(isRunning ? .red : .secondary)
                Spacer()
                Label(
                    isPaneSynced
                        ? String(localized: "workspace.synced.status", defaultValue: "Synced", bundle: .module)
                        : String(localized: "workspace.unsynced.status", defaultValue: "Preview", bundle: .module),
                    systemImage: isPaneSynced ? "link.circle.fill" : "rectangle.split.2x1"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(isPaneSynced ? .green : .secondary)
                Text(sizeString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let paneWidth = max((proxy.size.width - paneSpacing) / 2, 280)
                let paneSize = CGSize(width: paneWidth, height: proxy.size.height)
                let syncedContentSize = fittedPreviewSize(
                    in: CGSize(width: max(paneSize.width - 24, 1), height: max(paneSize.height - 64, 1))
                )

                HStack(alignment: .top, spacing: paneSpacing) {
                    TerminalPaneMockView()
                        .frame(width: paneWidth, height: paneSize.height)

                    SyncedWindowPaneView(
                        image: image,
                        window: window,
                        contentSize: syncedContentSize,
                        isPaneSynced: isPaneSynced,
                        onNativeSlotFrameChange: onNativeSlotFrameChange,
                        onSyncPane: onSyncPane,
                        onDetachPane: onDetachPane,
                        onMouseInput: onMouseInput,
                        onScrollInput: onScrollInput,
                        onKeyInput: onKeyInput
                    )
                    .frame(width: paneWidth, height: paneSize.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: workspaceHeight)
        }
    }

    private func fittedPreviewSize(in availableSize: CGSize) -> CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else {
            return .zero
        }

        let scale = min(
            availableSize.width / previewSize.width,
            availableSize.height / previewSize.height,
            1
        )
        return CGSize(
            width: max((previewSize.width * scale).rounded(.down), 1),
            height: max((previewSize.height * scale).rounded(.down), 1)
        )
    }

    private var sizeString: String {
        let format = String(localized: "window.frame.compact", defaultValue: "%.0f x %.0f", bundle: .module)
        return String(format: format, previewSize.width, previewSize.height)
    }
}

private struct TerminalPaneMockView: View {
    private var lines: [String] {
        [
            String(localized: "workspace.terminal.line1", defaultValue: "$ cmux run agent", bundle: .module),
            String(localized: "workspace.terminal.line2", defaultValue: "watching workspace...", bundle: .module),
            String(localized: "workspace.terminal.line3", defaultValue: "right pane can become another app", bundle: .module),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneTitleBarView(
                title: String(localized: "workspace.terminal.title", defaultValue: "Terminal", bundle: .module),
                subtitle: String(localized: "workspace.terminal.subtitle", defaultValue: "local zsh", bundle: .module)
            )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}

private struct SyncedWindowPaneView: View {
    let image: CGImage?
    let window: HostWindow
    let contentSize: CGSize
    let isPaneSynced: Bool
    let onNativeSlotFrameChange: (NativeWindowSlotFrame) -> Void
    let onSyncPane: () -> Void
    let onDetachPane: () -> Void
    let onMouseInput: (WindowMouseInput) -> Void
    let onScrollInput: (WindowScrollInput) -> Void
    let onKeyInput: (WindowKeyInput) -> Void

    private var title: String {
        window.hasTitle
            ? window.title
            : String(localized: "window.untitled", defaultValue: "Untitled", bundle: .module)
    }

    private var subtitle: String {
        let format = String(localized: "workspace.synced.subtitle", defaultValue: "%@ - window %@", bundle: .module)
        return String(format: format, window.ownerName, String(window.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneTitleBarView(title: title, subtitle: subtitle) {
                Button(action: isPaneSynced ? onDetachPane : onSyncPane) {
                    Label(
                        isPaneSynced
                            ? String(localized: "button.detachPane", defaultValue: "Detach", bundle: .module)
                            : String(localized: "button.syncPane", defaultValue: "Sync Into Pane", bundle: .module),
                        systemImage: isPaneSynced ? "rectangle.portrait.and.arrow.right" : "link"
                    )
                }
            }

            ZStack {
                Color(nsColor: .controlBackgroundColor)

                if let image {
                    if isPaneSynced {
                        StaticWindowPreview(image: image)
                            .frame(width: contentSize.width, height: contentSize.height)
                    } else {
                        InteractiveWindowPreview(
                            image: image,
                            window: window,
                            onMouse: onMouseInput,
                            onScroll: onScrollInput,
                            onKey: onKeyInput
                        )
                        .frame(width: contentSize.width, height: contentSize.height)
                    }
                } else {
                    ContentUnavailableView(
                        String(localized: "detail.livePreview.waiting", defaultValue: "Waiting for live video", bundle: .module),
                        systemImage: "video.slash"
                    )
                    .frame(width: contentSize.width, height: contentSize.height)
                }

                if isPaneSynced {
                    NativeWindowDockView(onFrameChange: onNativeSlotFrameChange)
                        .frame(width: contentSize.width, height: contentSize.height)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .frame(width: contentSize.width, height: contentSize.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isPaneSynced ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
        }
    }
}

private struct PaneTitleBarView<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, subtitle: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(.bar)
    }
}

private extension PaneTitleBarView where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
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
