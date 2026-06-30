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
        await providerStarted.wait()

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

    @Test func timedOutTicketReferenceRedemptionKeepsCooldownAfterTaskCompletes() async throws {
        let clock = ManualNanosecondClock()
        let gate = MobileCoreRPCTicketRedemptionGate(
            timedOutResetNanoseconds: 30 * 1_000_000_000,
            nowNanoseconds: clock.now
        )
        let providerStarted = AsyncFlag()
        let providerFinished = AsyncFlag()
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

        let timedOut = Task {
            try await gate.ticket(timeoutNanoseconds: 10_000_000) {
                await providerStarted.set()
                await releaseProvider.wait()
                await providerFinished.set()
                return redeemedTicket
            }
        }
        await providerStarted.wait()
        do {
            _ = try await timedOut.value
            Issue.record("Expected ticket redemption to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record(error)
        }
        await releaseProvider.release()
        await providerFinished.wait()

        do {
            _ = try await gate.ticket(timeoutNanoseconds: 60 * 1_000_000_000) {
                redeemedTicket
            }
            Issue.record("Expected ticket redemption cooldown to reject immediate retry")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record(error)
        }
    }

    @Test func repeatedTimedOutTicketReferenceRedemptionsDoNotWedgeRetry() async throws {
        let clock = ManualNanosecondClock()
        let gate = MobileCoreRPCTicketRedemptionGate(
            timedOutResetNanoseconds: 10_000_000,
            nowNanoseconds: clock.now
        )
        let firstStarted = AsyncFlag()
        let secondStarted = AsyncFlag()
        let neverReleaseProvider = AsyncReleaseGate()
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

        let firstTimedOut = Task {
            try await gate.ticket(timeoutNanoseconds: 1_000_000) {
                await firstStarted.set()
                await neverReleaseProvider.wait()
                return redeemedTicket
            }
        }
        await firstStarted.wait()
        do {
            _ = try await firstTimedOut.value
            Issue.record("Expected first ticket redemption to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record(error)
        }

        clock.advance(by: 20_000_000)
        let secondTimedOut = Task {
            try await gate.ticket(timeoutNanoseconds: 1_000_000) {
                await secondStarted.set()
                await neverReleaseProvider.wait()
                return redeemedTicket
            }
        }
        await secondStarted.wait()
        do {
            _ = try await secondTimedOut.value
            Issue.record("Expected second ticket redemption to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record(error)
        }

        clock.advance(by: 20_000_000)
        // Two providers are still stuck (they never resolve until released below),
        // so the gate has superseded two timed-out attempts. Retained abandoned
        // work must stay bounded to the most recent attempt rather than growing
        // one task per timeout.
        #expect(await gate.abandonedCount <= 1)
        let retry = try await gate.ticket(timeoutNanoseconds: 60 * 1_000_000_000) {
            redeemedTicket
        }
        #expect(retry.authToken == "ticket-secret")
        #expect(retry.ticketRef == "ticket-ref-123")
        #expect(await gate.abandonedCount <= 1)
        await neverReleaseProvider.release()
    }
}

// Protects test-clock state behind short synchronous critical sections because the gate reads time while actor-isolated.
private final class ManualNanosecondClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}
