#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Testing

@Suite struct TerminalLoadingDiagnosticsModelTests {
    @Test func connectedTailscaleRouteExplainsLoadingTerminalState() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.10", port: 58465)
        )

        let model = TerminalLoadingDiagnosticsModel.snapshot(
            workspaceName: "cmux",
            terminalCount: 0,
            macName: "Studio",
            connectionStatus: .connected,
            tailnetStatus: .active,
            activeRoute: route,
            storedRouteDescription: nil,
            connectionError: nil,
            connectionErrorGuidance: nil
        )

        #expect(model.title == "Loading terminals")
        #expect(model.message == "Waiting for Studio to send terminal metadata for this workspace.")
        #expect(model.rows[id: "mac"]?.value == "Studio · Connected")
        #expect(model.rows[id: "tailscale"]?.value == "Active")
        #expect(model.rows[id: "route"]?.value == "Tailscale · 100.64.0.10:58465")
        #expect(model.rows[id: "terminals"]?.value == "No terminal list yet")
    }

    @Test func inactiveTailscaleAndSavedRouteSurfaceNetworkGuidance() {
        let model = TerminalLoadingDiagnosticsModel.snapshot(
            workspaceName: "cmux",
            terminalCount: 0,
            macName: nil,
            connectionStatus: .unavailable,
            tailnetStatus: .inactiveOrNotInstalled,
            activeRoute: nil,
            storedRouteDescription: "100.64.0.20:58465",
            connectionError: "Timed out",
            connectionErrorGuidance: "Check that both devices are on the same Tailscale."
        )

        #expect(model.rows[id: "mac"]?.value == "cmux · Disconnected")
        #expect(model.rows[id: "mac"]?.tone == .warning)
        #expect(model.rows[id: "tailscale"]?.value == "Off or not installed")
        #expect(model.rows[id: "tailscale"]?.tone == .warning)
        #expect(model.rows[id: "route"]?.value == "Saved route · 100.64.0.20:58465")
        #expect(model.rows[id: "network"]?.value == "Check that both devices are on the same Tailscale.")
    }
}

private extension [TerminalLoadingDiagnosticsRow] {
    subscript(id id: String) -> TerminalLoadingDiagnosticsRow? {
        first { $0.id == id }
    }
}
#endif
