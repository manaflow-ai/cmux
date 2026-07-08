#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

struct TerminalLoadingDiagnosticsModelBuilder {
    let workspaceName: String
    let terminalCount: Int
    let macName: String?
    let connectionStatus: MobileMacConnectionStatus
    let tailnetStatus: TailnetStatus?
    let activeRoute: CmxAttachRoute?
    let storedRouteDescription: String?
    let connectionError: String?
    let connectionErrorGuidance: String?
    let loadingTimedOut: Bool

    func makeModel() -> TerminalLoadingDiagnosticsModel {
        let resolvedMacName = nonEmpty(macName) ?? nonEmpty(workspaceName) ?? L10n.string(
            "mobile.terminal.loading.macFallback",
            defaultValue: "Mac"
        )
        var rows: [TerminalLoadingDiagnosticsRow] = [
            TerminalLoadingDiagnosticsRow(
                id: "mac",
                label: L10n.string("mobile.terminal.loading.mac", defaultValue: "Mac"),
                value: String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.terminal.loading.macStatusFormat",
                        defaultValue: "%@ · %@"
                    ),
                    resolvedMacName,
                    connectionStatus.label
                ),
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
                value: routeText(
                    activeRoute: activeRoute,
                    storedRouteDescription: storedRouteDescription
                ),
                tone: activeRoute == nil && nonEmpty(storedRouteDescription) == nil ? .warning : .neutral
            ),
        ]

        if let detail = nonEmpty(connectionErrorGuidance) ?? nonEmpty(connectionError) {
            rows.append(TerminalLoadingDiagnosticsRow(
                id: "network",
                label: L10n.string("mobile.terminal.loading.network", defaultValue: "Network"),
                value: detail,
                tone: .warning
            ))
        }

        let text = headerText(resolvedMacName: resolvedMacName)
        return TerminalLoadingDiagnosticsModel(
            title: text.title,
            message: text.message,
            rows: rows,
            isLoading: connectionStatus == .connected && !loadingTimedOut
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func terminalStatusText(count: Int) -> String {
        guard count > 0 else {
            return L10n.string("mobile.terminal.loading.terminalsWaiting", defaultValue: "No terminal list yet")
        }
        return L10n.terminalCount(count)
    }

    private func headerText(resolvedMacName: String) -> (title: String, message: String) {
        if connectionStatus == .connected && terminalCount == 0 && loadingTimedOut {
            return (
                L10n.string("mobile.terminal.loading.emptyTitle", defaultValue: "No terminals yet"),
                String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.terminal.loading.emptyMessageFormat",
                        defaultValue: "%@ is connected. Create a terminal, or tap Refresh to check again."
                    ),
                    resolvedMacName
                )
            )
        }
        return (
            L10n.string("mobile.terminal.loading.title", defaultValue: "Loading terminals"),
            String.localizedStringWithFormat(
                L10n.string(
                    "mobile.terminal.loading.messageFormat",
                    defaultValue: "Waiting for %@ to send terminal metadata for this workspace."
                ),
                resolvedMacName
            )
        )
    }

    private func tailnetStatusText(_ status: TailnetStatus?) -> String {
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

    private func routeText(activeRoute: CmxAttachRoute?, storedRouteDescription: String?) -> String {
        if let activeRoute {
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.terminal.loading.routeActiveFormat",
                    defaultValue: "%@ · %@"
                ),
                routeKindText(activeRoute.kind),
                endpointText(activeRoute.endpoint)
            )
        }
        if let storedRouteDescription = nonEmpty(storedRouteDescription) {
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.terminal.loading.routeStoredFormat",
                    defaultValue: "Saved route · %@"
                ),
                storedRouteDescription
            )
        }
        return L10n.string("mobile.terminal.loading.routeMissing", defaultValue: "No saved route")
    }

    private func routeKindText(_ kind: CmxAttachTransportKind) -> String {
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

    private func endpointText(_ endpoint: CmxAttachEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(id, _, directAddrs, _):
            return directAddrs.first ?? id
        case let .url(url):
            return url
        }
    }

    private func tone(for status: MobileMacConnectionStatus) -> TerminalLoadingDiagnosticsTone {
        switch status {
        case .connected:
            return .good
        case .reconnecting:
            return .pending
        case .unavailable:
            return .warning
        }
    }

    private func tone(for status: TailnetStatus?) -> TerminalLoadingDiagnosticsTone {
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
#endif
