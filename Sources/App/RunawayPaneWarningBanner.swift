import CmuxFoundation
import SwiftUI

/// Top-of-content banner naming the terminal whose process tree is running
/// away (tab, workspace, command, process count, memory), with an action to
/// stop that tree. Mounted once per window over the workspace content and
/// shows only warnings for workspaces that window owns.
struct RunawayPaneWarningBanner: View {
    let center: RunawayPaneWarningCenter
    let tabManager: TabManager
    @State private var confirmingWarning: RunawayPaneWarning?

    var body: some View {
        let warning = center.warnings.first { warning in
            tabManager.tabs.contains { $0.id == warning.workspaceId }
        }
        Group {
            if let warning {
                card(for: warning)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: warning?.key)
    }

    private func card(for warning: RunawayPaneWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .cmuxFont(size: 15, weight: .semibold)
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    localized: "runawayPaneWarning.title",
                    defaultValue: "A terminal's processes are running away"
                ))
                .cmuxFont(size: 12.5, weight: .semibold)

                Text(warning.locationText)
                    .cmuxFont(size: 11.5, weight: .medium)
                    .lineLimit(1)

                Text(warning.detailText)
                    .cmuxFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    confirmingWarning = warning
                } label: {
                    Text(String(localized: "runawayPaneWarning.stop", defaultValue: "Stop Process Tree"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .confirmationDialog(
                    String(
                        localized: "runawayPaneWarning.confirm.title",
                        defaultValue: "Stop this terminal's process tree?"
                    ),
                    isPresented: Binding(
                        get: { confirmingWarning?.key == warning.key },
                        set: { if !$0 { confirmingWarning = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        confirmingWarning = nil
                        center.stopProcessTree(warning)
                    } label: {
                        Text(String(localized: "runawayPaneWarning.confirm.stop", defaultValue: "Stop"))
                    }
                    Button(role: .cancel) {
                        confirmingWarning = nil
                    } label: {
                        Text(String(localized: "runawayPaneWarning.confirm.cancel", defaultValue: "Cancel"))
                    }
                } message: {
                    Text(String(
                        localized: "runawayPaneWarning.confirm.message",
                        defaultValue: "cmux sends SIGTERM, then SIGKILL, to every job running in this terminal. The shell stays open."
                    ))
                }

                Button {
                    center.dismiss(warning)
                } label: {
                    Image(systemName: "xmark")
                        .cmuxFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "runawayPaneWarning.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "runawayPaneWarning.dismiss", defaultValue: "Dismiss"))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .frame(maxWidth: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RunawayPaneWarningBanner")
    }
}
