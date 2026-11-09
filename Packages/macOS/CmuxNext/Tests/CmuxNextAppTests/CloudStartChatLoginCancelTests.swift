@testable import CmuxNextApp
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A chat start's harness login runs beside its folder copy (`async let`, ``CloudStartChat/run(_:from:report:)``). When
/// the copy fails the start throws before it awaits the login, which Swift then cancels: the start record says
/// `cancelled`, never "failed: CancellationError" (capture run 42157718918, 03:49:27), nor "cached login unreadable"
/// when the cancellation cut its Keychain read short.
@MainActor
struct CloudStartChatLoginCancelTests {
    /// What ``CloudStartChat/passHarnessLogin(harness:machine:codexPrompt:ask:)`` records, with its Keychain read replaced by
    /// `cached` and its transfer by `transfer`: the same cached-login step, then the transfer, then the same record of a throw.
    private static func record(cached: () async -> CloudCredentialTransfer.CachedLogin = { .cached },
                               _ transfer: () async throws -> Void) async -> String {
        do {
            if let outcome = try await CloudCredentialTransfer.CachedLogin.startOutcome(cached) { return outcome }
            try await transfer()
            return "installed"
        } catch {
            return CloudHarnessLoginDecision.loginOutcome(error, cancelled: Task.isCancelled)
        }
    }

    private struct CopyFailed: Error {}

    @MainActor final class Box {
        var outcome: String?
        var transfers = 0
    }

    /// The start's shape: the login beside the copy, the copy failing before the login is awaited.
    private static func failTheCopy(beside login: @escaping @MainActor () async -> Void) async throws {
        async let _: Void = login()
        throw CopyFailed() // leaving the scope cancels the login and waits for it
    }

    @Test func aLoginCancelledBecauseTheCopyFailedIsRecordedAsCancelled() async {
        let box = Box()
        await #expect(throws: CopyFailed.self) {
            try await Self.failTheCopy { box.outcome = await Self.record { try await Task.sleep(for: .seconds(600)) } }
        }
        #expect(box.outcome == CloudHarnessLoginDecision.loginCancelled)
    }

    /// The cancellation lands while the Keychain is read: the read throws, ``CloudCredentialTransfer/cachedLogin(_:)``
    /// answers `unreadable`, and the start still records `cancelled` and transfers nothing.
    @Test func aCancellationDuringTheCachedLoginCheckIsRecordedAsCancelled() async {
        let box = Box()
        await #expect(throws: CopyFailed.self) {
            try await Self.failTheCopy {
                box.outcome = await Self.record(cached: {
                    await CloudCredentialTransfer.cachedLogin { try await Task.sleep(for: .seconds(600)); return nil }
                }) { box.transfers += 1 }
            }
        }
        #expect(box.outcome == CloudHarnessLoginDecision.loginCancelled)
        #expect(box.transfers == 0, "a cancelled start transfers nothing")
    }

    /// A Keychain that did not answer on a start nobody cancelled is still `unreadable`, and nothing is transferred.
    @Test func aRealUnreadableCacheIsStillUnreadable() async {
        let box = Box()
        let outcome = await Self.record(cached: { await CloudCredentialTransfer.cachedLogin { throw CloudCredentialTransfer.Failure.storeFailed } }) {
            box.transfers += 1
        }
        #expect(outcome == CloudCredentialTransfer.CachedLogin.unreadable.startOutcome)
        #expect(outcome != CloudHarnessLoginDecision.loginCancelled)
        #expect(box.transfers == 0)
        // No cached login is its own record; a cached one goes on to the transfer.
        #expect(await Self.record(cached: { .none }) { box.transfers += 1 } == CloudCredentialTransfer.CachedLogin.none.startOutcome)
        #expect(await Self.record(cached: { .cached }) { box.transfers += 1 } == "installed" && box.transfers == 1)
    }

    @Test func aTransferThatFailedOnItsOwnIsRecordedWithItsText() async {
        let outcome = await Self.record { throw CloudCredentialTransfer.Failure.deliveryFailed }
        #expect(outcome == "failed: " + (CloudCredentialTransfer.Failure.deliveryFailed.errorDescription ?? ""))
        #expect(outcome != CloudHarnessLoginDecision.loginCancelled)
    }

    @Test func anyErrorTheCancellationCausedIsCancelled() {
        #expect(CloudHarnessLoginDecision.loginOutcome(CancellationError(), cancelled: false) == CloudHarnessLoginDecision.loginCancelled)
        #expect(CloudHarnessLoginDecision.loginOutcome(URLError(.cancelled), cancelled: true) == CloudHarnessLoginDecision.loginCancelled)
        #expect(CloudHarnessLoginDecision.loginOutcome(URLError(.timedOut), cancelled: false) != CloudHarnessLoginDecision.loginCancelled)
    }
}
