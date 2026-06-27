import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAttachTokenFallbackTests {
    private static let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func attachTokenUnauthorizedRetriesWithStackAuthForOlderHosts() async throws {
        let transport = AttachTokenFallbackTransport()
        let (client, request) = try makeClientAndRequest(transport: transport)

        _ = try await client.sendRequest(request)

        let sent = try await transport.sentRequests()
        #expect(sent.count == 2)
        #expect(sent[0].attachToken == "ticket-secret")
        #expect(sent[0].stackAccessToken == nil)
        #expect(sent[1].attachToken == nil)
        #expect(sent[1].stackAccessToken == "fresh-stack-token")
    }

    @Test func attachTokenSpecificUnauthorizedDoesNotRetryWithStackAuth() async throws {
        let transport = AttachTokenFallbackTransport(
            firstErrorCode: "unauthorized",
            firstErrorMessage: "attach token no longer exists"
        )
        let (client, request) = try makeClientAndRequest(transport: transport)

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected attach-token-specific authorization failure")
        } catch let error as MobileShellConnectionError {
            guard case let .authorizationFailed(message) = error else {
                Issue.record("Expected authorizationFailed, got \(error)")
                return
            }
            #expect(message == "attach token no longer exists")
        } catch {
            Issue.record("Expected MobileShellConnectionError, got \(error)")
        }

        let sent = try await transport.sentRequests()
        #expect(sent.count == 1)
        #expect(sent[0].attachToken == "ticket-secret")
        #expect(sent[0].stackAccessToken == nil)
    }

    @Test func invalidAttachTokenRPCErrorDoesNotRetryWithStackAuth() async throws {
        let transport = AttachTokenFallbackTransport(
            firstErrorCode: "invalid_attach_token",
            firstErrorMessage: "Attach token is no longer valid."
        )
        let (client, request) = try makeClientAndRequest(transport: transport)

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected invalid attach token RPC error")
        } catch let error as MobileShellConnectionError {
            guard case let .rpcError(code, message) = error else {
                Issue.record("Expected rpcError, got \(error)")
                return
            }
            #expect(code == "invalid_attach_token")
            #expect(message == "Attach token is no longer valid.")
        } catch {
            Issue.record("Expected MobileShellConnectionError, got \(error)")
        }

        let sent = try await transport.sentRequests()
        #expect(sent.count == 1)
        #expect(sent[0].attachToken == "ticket-secret")
        #expect(sent[0].stackAccessToken == nil)
    }

    private func makeClientAndRequest(
        transport: AttachTokenFallbackTransport
    ) throws -> (MobileCoreRPCClient, Data) {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            stackAccessToken: "fresh-stack-token",
            now: { Self.fixedNow }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Self.fixedNow.addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.list",
            params: ["workspace_id": "workspace-main"]
        )
        return (client, request)
    }
}
