import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceConnectionInfoView: View {
    private static let refreshInterval: Duration = .seconds(1)

    let workspace: MobileWorkspacePreview
    let diagnosticsProvider: (MobileWorkspacePreview) async -> CmxConnectionDiagnostics?
    let clock: any Clock<Duration>

    @State private var diagnostics: CmxConnectionDiagnostics?
    @State private var sawRelay = false

    init(
        workspace: MobileWorkspacePreview,
        diagnosticsProvider: @escaping (MobileWorkspacePreview) async -> CmxConnectionDiagnostics?,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.workspace = workspace
        self.diagnosticsProvider = diagnosticsProvider
        self.clock = clock
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.transport", defaultValue: "Transport"),
                        value: transportText
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.path", defaultValue: "Path"),
                        value: pathText,
                        statusColor: pathStatusColor
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.latency", defaultValue: "Latency"),
                        value: latencyText
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.relay", defaultValue: "Relay"),
                        value: relayText
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.endpoint", defaultValue: "Endpoint"),
                        value: endpointText
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.data", defaultValue: "Data"),
                        value: dataText
                    )
                    WorkspaceConnectionInfoRow(
                        title: L10n.string("mobile.workspace.connectionInfo.upgradeStatus", defaultValue: "Upgrade status"),
                        value: upgradeStatusText
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.workspace.connectionInfo.title", defaultValue: "Connection info…"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task(id: workspace.id) {
            await refreshLoop()
        }
    }

    private var currentDiagnostics: CmxConnectionDiagnostics {
        diagnostics ?? CmxConnectionDiagnostics(transportKind: .network, pathKind: .unknown)
    }

    private var transportText: String {
        switch currentDiagnostics.transportKind {
        case .iroh:
            L10n.string("mobile.workspace.connectionInfo.transport.iroh", defaultValue: "iroh")
        case .network:
            L10n.string("mobile.workspace.connectionInfo.transport.lan", defaultValue: "LAN")
        }
    }

    private var pathText: String {
        switch currentDiagnostics.pathKind {
        case .direct:
            L10n.string("mobile.workspace.connectionInfo.path.direct", defaultValue: "Direct")
        case .relay:
            L10n.string("mobile.workspace.connectionInfo.path.relay", defaultValue: "Relay")
        case .mixed:
            L10n.string("mobile.workspace.connectionInfo.path.mixed", defaultValue: "Mixed")
        case .lan:
            L10n.string("mobile.workspace.connectionInfo.path.lan", defaultValue: "LAN")
        case .unknown:
            L10n.string("mobile.workspace.connectionInfo.unknown", defaultValue: "Unknown")
        }
    }

    private var latencyText: String {
        guard let rttMs = currentDiagnostics.rttMs else {
            return L10n.string("mobile.workspace.connectionInfo.unavailable", defaultValue: "—")
        }
        return String(
            format: L10n.string("mobile.workspace.connectionInfo.latency.msFormat", defaultValue: "%.0f ms"),
            rttMs
        )
    }

    private var relayText: String {
        switch currentDiagnostics.pathKind {
        case .direct, .lan:
            L10n.string("mobile.workspace.connectionInfo.relay.directNone", defaultValue: "Direct, no relay")
        case .relay, .mixed, .unknown:
            currentDiagnostics.relayLabel
                ?? L10n.string("mobile.workspace.connectionInfo.unknown", defaultValue: "Unknown")
        }
    }

    private var endpointText: String {
        guard let id = currentDiagnostics.remoteEndpointId, !id.isEmpty else {
            return L10n.string("mobile.workspace.connectionInfo.unavailable", defaultValue: "—")
        }
        guard id.count > 16 else { return id }
        return "\(id.prefix(12))…"
    }

    private var dataText: String {
        guard let sent = currentDiagnostics.bytesSent,
              let received = currentDiagnostics.bytesReceived else {
            return L10n.string("mobile.workspace.connectionInfo.unavailable", defaultValue: "—")
        }
        return String(
            format: L10n.string(
                "mobile.workspace.connectionInfo.data.sentReceivedFormat",
                defaultValue: "Sent %@ / received %@"
            ),
            Self.byteText(sent),
            Self.byteText(received)
        )
    }

    private var upgradeStatusText: String {
        switch currentDiagnostics.pathKind {
        case .direct where sawRelay:
            L10n.string("mobile.workspace.connectionInfo.upgradeStatus.upgraded", defaultValue: "Relay → Direct (upgraded)")
        case .direct, .lan:
            L10n.string("mobile.workspace.connectionInfo.upgradeStatus.direct", defaultValue: "Direct")
        case .relay:
            L10n.string("mobile.workspace.connectionInfo.upgradeStatus.relayed", defaultValue: "Relayed")
        case .mixed:
            L10n.string("mobile.workspace.connectionInfo.upgradeStatus.mixed", defaultValue: "Relay + Direct")
        case .unknown:
            L10n.string("mobile.workspace.connectionInfo.unknown", defaultValue: "Unknown")
        }
    }

    private var pathStatusColor: Color {
        switch currentDiagnostics.pathKind {
        case .direct, .lan:
            .green
        case .relay, .mixed:
            .orange
        case .unknown:
            .gray
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            do {
                // Live diagnostics polling: paced by an injected clock and cancelled with the sheet task.
                try await clock.sleep(for: Self.refreshInterval)
            } catch {
                break
            }
        }
    }

    private func refreshOnce() async {
        let next = await diagnosticsProvider(workspace)
        diagnostics = next
        if let next, next.pathKind == .relay || next.pathKind == .mixed || next.relayLabel != nil {
            sawRelay = true
        }
    }

    private static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

private struct WorkspaceConnectionInfoRow: View {
    let title: String
    let value: String
    var statusColor: Color?

    var body: some View {
        HStack(spacing: 12) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
            }
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
