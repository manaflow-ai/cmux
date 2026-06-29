import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCTicketRedemptionGateTests {
    @Test func cancelledTicketReferenceRedemptionGateAllowsImmediateRetry() async throws {
        let gate = MobileCoreRPCTicketRedemptionGate(timedOutResetNanoseconds: 30 * 1_000_000_000)
        let providerStarted = AsyncFlag()
        let releaseProvider = AsyncReleaseGate()
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let redeemedTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            ticketRef: "ticket-ref-123",
            authToken: "ticket-secret"
        )

        let cancelled = Task {
            try await gate.ticket(timeoutNanoseconds: 60 * 1_000_000_000) {
                await providerStarted.set()
                await releaseProvider.wait()
                try Task.checkCancellation()
                return redeemedTicket
            }
        }
        var sawProviderStart = false
        for _ in 0..<1000 {
            if await providerStarted.isSet() {
                sawProviderStart = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(sawProviderStart)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        let retry = try await gate.ticket(timeoutNanoseconds: 60 * 1_000_000_000) {
            redeemedTicket
        }
        #expect(retry.authToken == "ticket-secret")
        #expect(retry.ticketRef == "ticket-ref-123")

        await releaseProvider.release()
    }
}
