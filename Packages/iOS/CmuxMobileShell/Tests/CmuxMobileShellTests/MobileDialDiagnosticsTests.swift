import CMUXMobileCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileDialDiagnosticsTests {
    @Test func diagnosticsDoNotDowngradeFromIrohToRawTailscale() async throws {
        let endpointID = String(repeating: "1", count: 64)
        let irohRoute = try CmxAttachRoute(
            id: "iroh-primary",
            kind: .iroh,
            endpoint: .peer(
                id: endpointID,
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
        let recorder = DialDiagnosticRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: DialDiagnosticTransportFactory(
                router: LivenessHostRouter(),
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

        await #expect(throws: CmxNetworkByteTransportError.self) {
            _ = try await store.connect(ticket: ticket)
        }

        let lines = await recorder.lines()
        #expect(lines.count == 2)
        guard lines.count == 2 else {
            Issue.record("unexpected dial diagnostics: \(lines)")
            return
        }
        #expect(lines[0] == "mobile.dial.attempt index=1 route_id=iroh-primary kind=iroh endpoint=peer:11111111,hints:1")
        #expect(lines[1].hasPrefix("mobile.dial.failed index=1 route_id=iroh-primary kind=iroh failure_kind=hostUnreachable elapsed_ms="))
        let combined = lines.joined(separator: "\n")
        #expect(!combined.contains(endpointID))
        #expect(!combined.contains("never-log-this"))
        #expect(!combined.contains("sensitive transport detail"))
        #expect(!combined.contains("tailscale-fallback"))
        #expect(!combined.contains("100.71.210.41"))
    }

    @Test func diagnosticsFollowFallbackRouteOrder() async throws {
        let firstRoute = try CmxAttachRoute(
            id: "debug-primary",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 44_001),
            priority: 1
        )
        let fallbackRoute = try CmxAttachRoute(
            id: "debug-fallback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 44_002),
            priority: 2
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [fallbackRoute, firstRoute]
        )
        let recorder = DialDiagnosticRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: DialDiagnosticTransportFactory(
                router: LivenessHostRouter(),
                failingRouteID: firstRoute.id
            ),
            now: Date.init,
            supportedRouteKinds: [.debugLoopback]
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
        #expect(lines[0] == "mobile.dial.attempt index=1 route_id=debug-primary kind=debug_loopback endpoint=host_port:redacted,port:44001")
        #expect(lines[1].hasPrefix("mobile.dial.failed index=1 route_id=debug-primary kind=debug_loopback failure_kind=hostUnreachable elapsed_ms="))
        #expect(lines[2] == "mobile.dial.attempt index=2 route_id=debug-fallback kind=debug_loopback endpoint=host_port:redacted,port:44002")
        #expect(lines[3].hasPrefix("mobile.dial.connected index=2 route_id=debug-fallback kind=debug_loopback elapsed_ms="))
        #expect(!lines.joined(separator: "\n").contains("127.0.0.1"))
        #expect(store.connectionState == .connected)
    }
}
