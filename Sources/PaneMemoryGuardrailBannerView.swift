import CmuxPanes
import SwiftUI

/// Top-of-content dismissible banner shown when a pane's process tree crosses
/// the runaway-memory threshold. Reads the guardrail service held by the
/// composition root; mounted once as an overlay on the workspace content area
/// (outside the sidebar list, so the observed state stays outside the
/// snapshot-boundary rule). Stays silent while `activeBanner` is nil.
struct PaneMemoryGuardrailBanner: View {
    let guardrail: PaneMemoryGuardrailService
    let tabManager: TabManager
    @State private var isConfirmingKill = false
    @State private var killConfirmationWarning: PaneMemoryWarning?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter
    }()

    var body: some View {
        Group {
            if let warning = guardrail.activeBanner,
               tabManager.ownsPaneMemoryGuardrailWarning(warning) {
                bannerCard(for: warning)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: guardrail.activeBanner)
        .onChange(of: guardrail.activeBanner?.key) { _, activeKey in
            guard killConfirmationWarning?.key != activeKey else { return }
            killConfirmationWarning = nil
            isConfirmingKill = false
        }
        .onChange(of: isConfirmingKill) { _, isPresented in
            if !isPresented { killConfirmationWarning = nil }
        }
    }

    @ViewBuilder
    private func bannerCard(for warning: PaneMemoryWarning) -> some View {
        let memoryText = Self.byteFormatter.string(fromByteCount: warning.memoryBytes)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    localized: "paneMemoryGuardrail.banner.title",
                    defaultValue: "A pane is using a lot of memory"
                ))
                .font(.system(size: 12.5, weight: .semibold))

                Text(detailText(for: warning, memoryText: memoryText))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    killConfirmationWarning = warning
                    isConfirmingKill = true
                } label: {
                    Text(String(
                        localized: "paneMemoryGuardrail.banner.kill",
                        defaultValue: "Kill Pane Process"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .confirmationDialog(
                    String(
                        localized: "paneMemoryGuardrail.confirm.title",
                        defaultValue: "Kill this pane's runaway process?"
                    ),
                    isPresented: $isConfirmingKill,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        guard let selected = killConfirmationWarning,
                              guardrail.activeBanner?.key == selected.key else { return }
                        killConfirmationWarning = nil
                        guardrail.killPaneProcess(for: selected)
                    } label: {
                        Text(String(
                            localized: "paneMemoryGuardrail.confirm.kill",
                            defaultValue: "Kill Process"
                        ))
                    }
                    Button(role: .cancel) {
                        killConfirmationWarning = nil
                    } label: {
                        Text(String(localized: "paneMemoryGuardrail.confirm.cancel", defaultValue: "Cancel"))
                    }
                } message: {
                    Text(String(
                        localized: "paneMemoryGuardrail.confirm.message",
                        defaultValue: "This sends SIGTERM then SIGKILL to high-memory process groups in the pane. Other process groups are left alone."
                    ))
                }

                Button {
                    guardrail.dismissActiveBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "paneMemoryGuardrail.banner.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "paneMemoryGuardrail.banner.dismiss", defaultValue: "Dismiss"))
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
        .frame(maxWidth: 560)
        .accessibilityIdentifier("PaneMemoryGuardrailBanner")
    }

    private func detailText(for warning: PaneMemoryWarning, memoryText: String) -> String {
        let paneName = warning.paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = warning.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let location: String
        if !workspaceName.isEmpty {
            location = String.localizedStringWithFormat(
                String(
                    localized: "paneMemoryGuardrail.banner.location",
                    defaultValue: "%1$@ in %2$@"
                ),
                paneName.isEmpty ? String(localized: "paneMemoryGuardrail.banner.unnamedPane", defaultValue: "Terminal") : paneName,
                workspaceName
            )
        } else {
            location = paneName.isEmpty ? String(localized: "paneMemoryGuardrail.banner.unnamedPane", defaultValue: "Terminal") : paneName
        }

        if let command = warning.foregroundCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return String.localizedStringWithFormat(
                String(
                    localized: "paneMemoryGuardrail.banner.detailWithCommand",
                    defaultValue: "%1$@ — %2$@ (running %3$@)"
                ),
                location, memoryText, command
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "paneMemoryGuardrail.banner.detail",
                defaultValue: "%1$@ — %2$@"
            ),
            location, memoryText
        )
    }
}

extension TabManager {
    func ownsPaneMemoryGuardrailWarning(_ warning: PaneMemoryWarning?) -> Bool {
        guard let warning else { return false }
        return tabs.contains { $0.id == warning.workspaceId }
    }
}
