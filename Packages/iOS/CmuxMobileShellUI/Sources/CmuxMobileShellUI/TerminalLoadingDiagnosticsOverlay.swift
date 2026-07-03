#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalLoadingDiagnosticsOverlay: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let tailnetStatus: TailnetStatus?
    let activeRoute: CmxAttachRoute?
    let storedRouteDescription: String?
    let connectionError: String?
    let connectionErrorGuidance: String?
    let createTerminal: () -> Void
    let refreshConnection: () -> Void
    let canCreateTerminal: Bool

    private static let terminalMetadataTimeout: Duration = .seconds(10)

    @State private var terminalMetadataTimedOut = false
    @State private var refreshGeneration = 0

    private var model: TerminalLoadingDiagnosticsModel {
        TerminalLoadingDiagnosticsModel(
            workspaceName: workspace.name,
            terminalCount: workspace.terminals.count,
            macName: workspace.macDisplayName ?? host,
            connectionStatus: workspace.macConnectionStatus ?? connectionStatus,
            tailnetStatus: tailnetStatus,
            activeRoute: activeRoute,
            storedRouteDescription: storedRouteDescription,
            connectionError: connectionError,
            connectionErrorGuidance: connectionErrorGuidance,
            loadingTimedOut: terminalMetadataTimedOut
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(model.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(model.rows) { row in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(color(for: row.tone))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(row.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer(minLength: 8)
                        Text(row.value)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Button(action: retryLoading) {
                    Label(
                        L10n.string("mobile.terminal.loading.refresh", defaultValue: "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobileLoadingRefreshButton")

                if canCreateTerminal {
                    Button(action: createTerminal) {
                        Label(
                            L10n.string("mobile.terminal.loading.createTerminal", defaultValue: "Create Terminal"),
                            systemImage: "plus"
                        )
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("MobileLoadingCreateTerminalButton")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("MobileTerminalLoadingDiagnostics")
        .task(id: deadlineTaskID) {
            await updateTerminalMetadataDeadline()
        }
    }

    private func color(for tone: TerminalLoadingDiagnosticsTone) -> Color {
        switch tone {
        case .good:
            return .green
        case .pending:
            return .orange
        case .warning:
            return .red
        case .neutral:
            return .white.opacity(0.45)
        }
    }

    private var effectiveConnectionStatus: MobileMacConnectionStatus {
        workspace.macConnectionStatus ?? connectionStatus
    }

    private var deadlineTaskID: String {
        [
            workspace.id.rawValue,
            String(workspace.terminals.count),
            connectionStatusKey(effectiveConnectionStatus),
            String(refreshGeneration),
        ].joined(separator: ":")
    }

    private func updateTerminalMetadataDeadline() async {
        terminalMetadataTimedOut = false
        guard effectiveConnectionStatus == .connected,
              workspace.terminals.isEmpty else {
            return
        }
        do {
            try await ContinuousClock().sleep(for: Self.terminalMetadataTimeout)
        } catch {
            return
        }
        guard effectiveConnectionStatus == .connected,
              workspace.terminals.isEmpty else {
            return
        }
        terminalMetadataTimedOut = true
    }

    private func retryLoading() {
        terminalMetadataTimedOut = false
        refreshGeneration &+= 1
        refreshConnection()
    }

    private func connectionStatusKey(_ status: MobileMacConnectionStatus) -> String {
        switch status {
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .unavailable:
            return "unavailable"
        }
    }
}
#endif
