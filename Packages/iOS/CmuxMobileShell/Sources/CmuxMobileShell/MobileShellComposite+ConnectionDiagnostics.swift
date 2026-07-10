public import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Returns live connection diagnostics for the Mac that owns `workspace`.
    public func connectionDiagnostics(
        for workspace: MobileWorkspacePreview
    ) async -> CmxConnectionDiagnostics? {
        if let macDeviceID = workspace.macDeviceID ?? foregroundMacDeviceID,
           let connection = connections[macDeviceID] {
            if let diagnostics = await connection.client.connectionDiagnostics() {
                return diagnostics
            }
            return Self.fallbackDiagnostics(for: connection.route)
        }

        if let diagnostics = await remoteClient?.connectionDiagnostics() {
            return diagnostics
        }
        if let activeRoute {
            return Self.fallbackDiagnostics(for: activeRoute)
        }
        return CmxConnectionDiagnostics(transportKind: .network, pathKind: .unknown)
    }

    private static func fallbackDiagnostics(for route: CmxAttachRoute) -> CmxConnectionDiagnostics {
        switch route.kind {
        case .iroh:
            if case let .peer(id, _, _, relayURL) = route.endpoint {
                return CmxConnectionDiagnostics(
                    transportKind: .iroh,
                    pathKind: .unknown,
                    relayLabel: relayLabel(for: relayURL),
                    remoteEndpointId: id.isEmpty ? nil : id
                )
            }
            return CmxConnectionDiagnostics(transportKind: .iroh, pathKind: .unknown)
        case .tailscale, .debugLoopback:
            return CmxConnectionDiagnostics(transportKind: .network, pathKind: .lan)
        case .websocket:
            return CmxConnectionDiagnostics(transportKind: .network, pathKind: .unknown)
        }
    }

    private static func relayLabel(for relayURL: String?) -> String? {
        guard let relayURL, !relayURL.isEmpty else { return nil }
        guard let host = URL(string: relayURL)?.host(), !host.isEmpty else {
            return relayURL
        }
        return host.split(separator: ".").first.map(String.init) ?? relayURL
    }
}
