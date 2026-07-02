#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalLoadingDiagnosticsRow: Equatable, Identifiable {
    enum Tone: Equatable {
        case good
        case pending
        case warning
        case neutral
    }

    let id: String
    let label: String
    let value: String
    let tone: Tone
}

struct TerminalLoadingDiagnosticsModel: Equatable {
    let title: String
    let message: String
    let rows: [TerminalLoadingDiagnosticsRow]

    static func snapshot(
        workspaceName: String,
        terminalCount: Int,
        macName: String?,
        connectionStatus: MobileMacConnectionStatus,
        tailnetStatus: TailnetStatus?,
        activeRoute: CmxAttachRoute?,
        storedRouteDescription: String?,
        connectionError: String?,
        connectionErrorGuidance: String?
    ) -> Self {
        let resolvedMacName = Self.nonEmpty(macName) ?? Self.nonEmpty(workspaceName) ?? L10n.string(
            "mobile.terminal.loading.macFallback",
            defaultValue: "Mac"
        )
        var rows: [TerminalLoadingDiagnosticsRow] = [
            TerminalLoadingDiagnosticsRow(
                id: "mac",
                label: L10n.string("mobile.terminal.loading.mac", defaultValue: "Mac"),
                value: "\(resolvedMacName) · \(connectionStatus.label)",
                tone: tone(for: connectionStatus)
            ),
            TerminalLoadingDiagnosticsRow(
                id: "terminals",
                label: L10n.string("mobile.terminal.loading.terminals", defaultValue: "Terminals"),
                value: terminalStatusText(count: terminalCount),
                tone: terminalCount > 0 ? .good : .pending
            ),
            TerminalLoadingDiagnosticsRow(
                id: "tailscale",
                label: L10n.string("mobile.terminal.loading.tailscale", defaultValue: "Tailscale"),
                value: tailnetStatusText(tailnetStatus),
                tone: tone(for: tailnetStatus)
            ),
            TerminalLoadingDiagnosticsRow(
                id: "route",
                label: L10n.string("mobile.terminal.loading.route", defaultValue: "Route"),
                value: routeText(activeRoute: activeRoute, storedRouteDescription: storedRouteDescription),
                tone: activeRoute == nil && Self.nonEmpty(storedRouteDescription) == nil ? .warning : .neutral
            ),
        ]

        if let detail = Self.nonEmpty(connectionErrorGuidance) ?? Self.nonEmpty(connectionError) {
            rows.append(TerminalLoadingDiagnosticsRow(
                id: "network",
                label: L10n.string("mobile.terminal.loading.network", defaultValue: "Network"),
                value: detail,
                tone: .warning
            ))
        }

        return Self(
            title: L10n.string("mobile.terminal.loading.title", defaultValue: "Loading terminals"),
            message: String(
                format: L10n.string(
                    "mobile.terminal.loading.messageFormat",
                    defaultValue: "Waiting for %@ to send terminal metadata for this workspace."
                ),
                resolvedMacName
            ),
            rows: rows
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func terminalStatusText(count: Int) -> String {
        guard count > 0 else {
            return L10n.string("mobile.terminal.loading.terminalsWaiting", defaultValue: "No terminal list yet")
        }
        return L10n.terminalCount(count)
    }

    private static func tailnetStatusText(_ status: TailnetStatus?) -> String {
        switch status {
        case .active:
            return L10n.string("mobile.terminal.loading.tailscale.active", defaultValue: "Active")
        case .inactiveOrNotInstalled:
            return L10n.string("mobile.terminal.loading.tailscale.inactive", defaultValue: "Off or not installed")
        case .unknown:
            return L10n.string("mobile.terminal.loading.tailscale.unknown", defaultValue: "Unknown")
        case nil:
            return L10n.string("mobile.terminal.loading.tailscale.notChecked", defaultValue: "Not checked")
        }
    }

    private static func routeText(activeRoute: CmxAttachRoute?, storedRouteDescription: String?) -> String {
        if let activeRoute {
            return "\(routeKindText(activeRoute.kind)) · \(endpointText(activeRoute.endpoint))"
        }
        if let storedRouteDescription = nonEmpty(storedRouteDescription) {
            return String(
                format: L10n.string(
                    "mobile.terminal.loading.routeStoredFormat",
                    defaultValue: "Saved route · %@"
                ),
                storedRouteDescription
            )
        }
        return L10n.string("mobile.terminal.loading.routeMissing", defaultValue: "No saved route")
    }

    private static func routeKindText(_ kind: CmxAttachTransportKind) -> String {
        switch kind {
        case .tailscale:
            return L10n.string("mobile.terminal.loading.route.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            return L10n.string("mobile.terminal.loading.route.debugLoopback", defaultValue: "Debug loopback")
        case .iroh:
            return L10n.string("mobile.terminal.loading.route.iroh", defaultValue: "Iroh")
        case .websocket:
            return L10n.string("mobile.terminal.loading.route.websocket", defaultValue: "WebSocket")
        }
    }

    private static func endpointText(_ endpoint: CmxAttachEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(id, _, directAddrs, _):
            return directAddrs.first ?? id
        case let .url(url):
            return url
        }
    }

    private static func tone(for status: MobileMacConnectionStatus) -> TerminalLoadingDiagnosticsRow.Tone {
        switch status {
        case .connected:
            return .good
        case .reconnecting:
            return .pending
        case .unavailable:
            return .warning
        }
    }

    private static func tone(for status: TailnetStatus?) -> TerminalLoadingDiagnosticsRow.Tone {
        switch status {
        case .active:
            return .good
        case .inactiveOrNotInstalled:
            return .warning
        case .unknown, nil:
            return .neutral
        }
    }
}

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
    let canCreateTerminal: Bool

    private var model: TerminalLoadingDiagnosticsModel {
        TerminalLoadingDiagnosticsModel.snapshot(
            workspaceName: workspace.name,
            terminalCount: workspace.terminals.count,
            macName: workspace.macDisplayName ?? host,
            connectionStatus: workspace.macConnectionStatus ?? connectionStatus,
            tailnetStatus: tailnetStatus,
            activeRoute: activeRoute,
            storedRouteDescription: storedRouteDescription,
            connectionError: connectionError,
            connectionErrorGuidance: connectionErrorGuidance
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .accessibilityHidden(true)

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
        .padding(24)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("MobileTerminalLoadingDiagnostics")
    }

    private func color(for tone: TerminalLoadingDiagnosticsRow.Tone) -> Color {
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
}

extension WorkspaceDetailView {
    var loadingDiagnosticsMacSnapshot: MacComputerSnapshot? {
        guard let macDeviceID = workspace.macDeviceID,
              !macDeviceID.isEmpty else {
            return nil
        }
        return MacComputerSnapshot.snapshots(from: store).first { snapshot in
            snapshot.deviceId == macDeviceID || snapshot.aliasIDs.contains(macDeviceID)
        }
    }

    var activeLoadingDiagnosticsRoute: CmxAttachRoute? {
        guard let macDeviceID = workspace.macDeviceID,
              !macDeviceID.isEmpty else {
            return nil
        }
        if macDeviceID == store.connectedMacDeviceID {
            return store.activeRoute
        }
        guard let connectedMacDeviceID = store.connectedMacDeviceID,
              store.pairedMacAliasIDs(for: macDeviceID).contains(connectedMacDeviceID) else {
            return nil
        }
        return store.activeRoute
    }
}
#endif
