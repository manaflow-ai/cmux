import AppKit
import SwiftUI

struct MacAppPanelView: View {
    @ObservedObject var panel: MacAppPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .onAppear {
            panel.setVisibleInUI(true)
            panel.refreshWindows()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            panel.setVisibleInUI(visible)
            if visible { panel.refreshWindows() }
        }
        .onDisappear {
            panel.close()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: panel.displayIcon ?? "macwindow")
                .foregroundStyle(.secondary)
            Text(panel.displayTitle)
                .lineLimit(1)
            Spacer()
            if panel.selectedWindow != nil {
                Button(String(localized: "macApp.toolbar.change", defaultValue: "Change App")) {
                    panel.clearSelection()
                    panel.refreshWindows()
                }
                .buttonStyle(.borderless)
            }
            Button {
                panel.refreshWindows()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "macApp.toolbar.refresh.help", defaultValue: "Refresh available apps"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if let selectedWindow = panel.selectedWindow {
            ZStack {
                MacAppSurfaceRepresentable(
                    panel: panel,
                    isFocused: isFocused,
                    allowsPointerInput: allowsPointerInput,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                if panel.captureState != .streaming || panel.requiresAccessibilityPermission {
                    statusOverlay
                }
            }
            .id(selectedWindow.id)
        } else if panel.isLoadingWindows {
            ProgressView(String(localized: "macApp.picker.loading", defaultValue: "Finding open apps…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if panel.availableWindows.isEmpty {
            emptyState
        } else {
            windowPicker
        }
    }

    private var windowPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "macApp.picker.title", defaultValue: "Choose an open Mac app"))
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(panel.availableWindows) { window in
                    Button {
                        panel.selectWindow(window)
                        onRequestPanelFocus()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "macwindow")
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.applicationName)
                                    .font(.body.weight(.medium))
                                if !window.title.isEmpty {
                                    Text(window.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(String(localized: "macApp.picker.empty.title", defaultValue: "No capturable app windows"))
                .font(.headline)
            Text(
                panel.requiresScreenRecordingPermission
                    ? String(localized: "macApp.picker.permission.message", defaultValue: "Allow Screen Recording for cmux in System Settings, then refresh.")
                    : String(localized: "macApp.picker.empty.message", defaultValue: "Open an app window and refresh this pane.")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if panel.requiresScreenRecordingPermission {
                    Button(String(localized: "macApp.picker.openScreenRecording", defaultValue: "Open Screen Recording Settings")) {
                        panel.openScreenRecordingSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(String(localized: "macApp.picker.refresh", defaultValue: "Refresh")) {
                    panel.refreshWindows()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var statusOverlay: some View {
        VStack(spacing: 8) {
            Group {
                if panel.captureState == .permissionRequired {
                    Image(systemName: "record.circle")
                        .font(.title2)
                    Text(String(localized: "macApp.capture.permission", defaultValue: "Allow Screen Recording for cmux, then choose this app again."))
                    Button(String(localized: "macApp.picker.openScreenRecording", defaultValue: "Open Screen Recording Settings")) {
                        panel.openScreenRecordingSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if panel.requiresAccessibilityPermission {
                    Image(systemName: "hand.raised")
                        .font(.title2)
                    Text(String(localized: "macApp.capture.accessibility", defaultValue: "Allow Accessibility for cmux to interact with this app."))
                    Button(String(localized: "macApp.picker.openAccessibility", defaultValue: "Open Accessibility Settings")) {
                        panel.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if panel.captureState == .failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(String(localized: "macApp.capture.failed", defaultValue: "The app window could not be captured. Refresh and try again."))
                    Button(String(localized: "macApp.picker.refresh", defaultValue: "Refresh")) {
                        panel.refreshWindows()
                    }
                    .buttonStyle(.bordered)
                } else {
                    ProgressView()
                    Text(String(localized: "macApp.capture.starting", defaultValue: "Starting app mirror…"))
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
