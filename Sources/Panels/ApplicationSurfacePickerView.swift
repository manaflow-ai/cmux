import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ApplicationSurfacePickerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case permissionRequired
        case helperUnavailable
        case failed(String)
    }

    var windows: [ApplicationWindowDescriptor] = []
    var query = ""
    var selectedWindowID: UInt32?
    var phase: Phase = .idle

    var filteredWindows: [ApplicationWindowDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.owner.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    func replaceWindows(_ windows: [ApplicationWindowDescriptor]) {
        self.windows = windows
        if !windows.contains(where: { $0.windowID == selectedWindowID }) {
            selectedWindowID = windows.first?.windowID
        }
    }
}

struct ApplicationSurfacePickerView: View {
    @Bindable var model: ApplicationSurfacePickerModel
    let onRefresh: () -> Void
    let onSetUpPermissions: () -> Void
    let onSelect: (ApplicationWindowDescriptor) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityIdentifier("ApplicationSurfacePicker")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label(
                String(
                    localized: "applicationSurface.picker.title",
                    defaultValue: "Choose an application window"
                ),
                systemImage: "macwindow.on.rectangle"
            )
            .lineLimit(1)

            Spacer(minLength: 8)

            TextField(
                String(
                    localized: "applicationSurface.picker.search",
                    defaultValue: "Search windows"
                ),
                text: $model.query
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 220, maxWidth: 280)
            .accessibilityIdentifier("ApplicationSurfacePickerSearch")

            Button(action: onRefresh) {
                Label(
                    String(
                        localized: "applicationSurface.picker.refresh",
                        defaultValue: "Refresh"
                    ),
                    systemImage: "arrow.clockwise"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(model.phase == .loading)
            .help(
                String(
                    localized: "applicationSurface.picker.refresh",
                    defaultValue: "Refresh"
                )
            )
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            centeredStatus {
                ProgressView()
                    .controlSize(.small)
                Text(
                    String(
                        localized: "applicationSurface.picker.loading",
                        defaultValue: "Loading application windows…"
                    )
                )
                .foregroundStyle(.secondary)
            }
        case .permissionRequired:
            centeredStatus {
                Image(systemName: "hand.raised")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        localized: "applicationSurface.picker.permissionTitle",
                        defaultValue: "Set up application panes"
                    )
                )
                .font(.headline)
                Text(
                    String(
                        localized: "applicationSurface.picker.permissionsIncomplete",
                        defaultValue: "Accessibility and Screen Recording access are both required."
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Button(
                    String(
                        localized: "panel.application.permissionRequired.action",
                        defaultValue: "Set Up Permissions"
                    ),
                    action: onSetUpPermissions
                )
                .controlSize(.small)
                .accessibilityIdentifier("ApplicationSurfacePickerSetUpPermissions")
            }
        case .helperUnavailable:
            failureStatus(
                String(
                    localized: "applicationSurface.picker.helperUnavailable",
                    defaultValue: "cmux could not start the Computer Use helper."
                )
            )
        case .failed(let message):
            failureStatus(message)
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if model.filteredWindows.isEmpty {
            centeredStatus {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        localized: "applicationSurface.picker.empty",
                        defaultValue: "No matching application windows"
                    )
                )
                .font(.headline)
                Text(
                    String(
                        localized: "applicationSurface.picker.emptyDetail",
                        defaultValue: "Open a window in another app, then refresh."
                    )
                )
                .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredWindows) { window in
                        ApplicationSurfacePickerButton(
                            window: window,
                            action: {
                                model.selectedWindowID = window.windowID
                                onSelect(window)
                            }
                        )
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .accessibilityIdentifier("ApplicationSurfacePickerList")
        }
    }

    private func failureStatus(_ message: String) -> some View {
        centeredStatus {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button(
                String(
                    localized: "applicationSurface.picker.tryAgain",
                    defaultValue: "Try Again"
                ),
                action: onRefresh
            )
            .controlSize(.small)
        }
    }

    private func centeredStatus<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10, content: content)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ApplicationSurfacePickerButton: View {
    let window: ApplicationWindowDescriptor
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ApplicationSurfacePickerRow(window: window)
                .padding(.horizontal, 12)
                .background(
                    isHovering
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("ApplicationSurfaceWindow-\(window.windowID)")
    }
}

private struct ApplicationSurfacePickerRow: View {
    let window: ApplicationWindowDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = NSRunningApplication(
                    processIdentifier: pid_t(window.processID)
                )?.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .padding(5)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(window.owner)
                    Text(verbatim: "•")
                    Text(verbatim: "\(Int(window.width)) × \(Int(window.height))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
