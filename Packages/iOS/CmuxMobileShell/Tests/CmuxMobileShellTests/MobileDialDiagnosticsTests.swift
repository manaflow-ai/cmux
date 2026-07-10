import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileDialDiagnosticsTests {
    @Test func diagnosticsFollowIrohThenTailscalePriorityOrder() async throws {
        let irohRoute = try CmxAttachRoute(
            id: "iroh-primary",
            kind: .iroh,
            endpoint: .peer(
                id: "1234567890-full-endpoint-id",
                relayHint: nil,
                directAddrs: [],
                relayURL: "https://relay.example.com/path?token=never-log-this"
            ),
            priority: 1
        )
        let tailscaleRoute = try CmxAttachRoute(
            id: "tailscale-fallback",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort),
            priority: 2
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [tailscaleRoute, irohRoute]
        )
        let router = LivenessHostRouter()
        let recorder = DialDiagnosticRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: DialDiagnosticTransportFactory(
                router: router,
                failingRouteID: irohRoute.id
            ),
            now: Date.init,
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            dialLog: { line in await recorder.record(line) }
        )

        _ = try await store.connect(ticket: ticket)

        let lines = await recorder.lines()
        #expect(lines.count == 4)
        guard lines.count == 4 else {
            Issue.record("unexpected dial diagnostics: \(lines)")
            return
        }
        #expect(lines[0] == "mobile.dial.attempt index=1 route_id=iroh-primary kind=iroh endpoint=peer:12345678,relay:relay.example.com")
        #expect(lines[1].hasPrefix("mobile.dial.failed index=1 route_id=iroh-primary kind=iroh failure_kind=hostUnreachable elapsed_ms="))
        #expect(lines[2] == "mobile.dial.attempt index=2 route_id=tailscale-fallback kind=tailscale endpoint=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)")
        #expect(lines[3].hasPrefix("mobile.dial.connected index=2 route_id=tailscale-fallback kind=tailscale elapsed_ms="))
        let combined = lines.joined(separator: "\n")
        #expect(!combined.contains("1234567890-full-endpoint-id"))
        #expect(!combined.contains("never-log-this"))
        #expect(!combined.contains("sensitive transport detail"))
        #expect(store.connectionState == .connected)
    }
}
