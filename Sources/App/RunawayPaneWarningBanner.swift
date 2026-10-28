import CmuxFoundation
import SwiftUI

/// Banner naming the terminal whose process tree is running away (tab,
/// workspace, command, process count, memory), with an action to stop that
/// tree. Hosted natively above the terminal portals by
/// `RunawayPaneWarningOverlay`; takes a value snapshot and closures only.
struct RunawayPaneWarningBanner: View {
    let warning: RunawayPaneWarning
    let onStop: (RunawayPaneWarning) -> Void
    let onDismiss: (RunawayPaneWarning) -> Void
    @State private var isConfirming = false

    var body: some View {
        card(for: warning)
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

                if !warning.canStop {
                    Text(String(
                        localized: "runawayPaneWarning.cannotStop",
                        defaultValue: "cmux can't safely stop this process tree from here. Stop it in the terminal."
                    ))
                    .cmuxFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if warning.canStop {
                    Button(role: .destructive) {
                        isConfirming = true
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
                        isPresented: $isConfirming,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            isConfirming = false
                            onStop(warning)
                        } label: {
                            Text(String(localized: "runawayPaneWarning.confirm.stop", defaultValue: "Stop"))
                        }
                        Button(role: .cancel) {
                            isConfirming = false
                        } label: {
                            Text(String(localized: "runawayPaneWarning.confirm.cancel", defaultValue: "Cancel"))
                        }
                    } message: {
                        Text(String(
                            localized: "runawayPaneWarning.confirm.message",
                            defaultValue: "cmux stops the jobs this terminal started, including nested shells and suspended jobs, and force-quits any that don't exit. The terminal's own shell stays open."
                        ))
                    }
                }

                Button {
                    onDismiss(warning)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RunawayPaneWarningBanner")
    }
}
