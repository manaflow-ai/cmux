import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite("LAN RPC authorization")
struct MobileCoreRPCLanAuthTests {
    @Test("LAN Only never sends a Stack bearer over raw TCP")
    func lanOnlyRawRouteFailsClosedBeforeBearerFetch() async throws {
        let route = try hostPortRoute(
            kind: .lan,
            host: "192.168.1.20",
            port: 58_465
        )
        let transport = QueuedCancellationProbeTransport()
        let capture = TransportRequestCapture()
        let stackTokenRequested = AsyncFlag()
        let runtime = TestMobileSyncRuntime(
            transportFactory: IntentRecordingTransportFactory(
                transport: transport,
                capture: capture
            ),
            stackAccessTokenProvider: {
                await stackTokenRequested.set()
                return "must-not-cross-raw-lan"
            }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "123e4567-e89b-42d3-a456-426614174000",
            macDisplayName: "LAN Mac",
            routes: [route],
            expiresAt: nil
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true,
            transportMode: .lanOnly
        )

        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.list")
            )
            Issue.record("Expected raw LAN auth to fail closed")
        } catch MobileShellConnectionError.insecureManualRoute {
        } catch {
            Issue.record("Expected insecureManualRoute, got \(error)")
        }
        #expect(!(await stackTokenRequested.isSet()))
        #expect(capture.request() == nil)
        #expect(try await transport.sentRequests().isEmpty)
    }
}
