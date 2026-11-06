@testable import CmuxNextApp
import CmuxNextCloudCredentials
import Foundation
import Testing

/// A chat start's harness login runs beside its folder copy (`async let`, ``CloudStartChat/run(_:from:report:)``). When
/// the copy fails the start throws before it awaits the login, which Swift then cancels: the start record says
/// `cancelled`, never "failed: CancellationError" (capture run 42157718918, 03:49:27).
@MainActor
struct CloudStartChatLoginCancelTests {
    /// What ``CloudStartChat/passHarnessLogin(harness:machine:codexPrompt:ask:)`` records, with its transfer replaced by `transfer`.
    private static func record(_ transfer: () async throws -> Void) async -> String {
        do {
            try await transfer()
            return "installed"
        } catch where CloudStartChat.cancelledLogin(error, cancelled: Task.isCancelled) {
            return CloudStartChat.loginCancelled
        } catch {
            return "failed: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
        }
    }

    private struct CopyFailed: Error {}

    @MainActor final class Box { var outcome: String? }

    @Test func aLoginCancelledBecauseTheCopyFailedIsRecordedAsCancelled() async {
        let box = Box()
        // The start's shape: the login beside the copy, the copy failing before the login is awaited.
        func login() async {
            let outcome = await Self.record { try await Task.sleep(for: .seconds(600)) }
            box.outcome = outcome
        }
        func start() async throws {
            async let _: Void = login()
            throw CopyFailed() // leaving the scope cancels the login and waits for it
        }
        await #expect(throws: CopyFailed.self) { try await start() }
        #expect(box.outcome == CloudStartChat.loginCancelled)
    }

    @Test func aTransferThatFailedOnItsOwnIsRecordedWithItsText() async {
        let outcome = await Self.record { throw CloudCredentialTransfer.Failure.deliveryFailed }
        #expect(outcome == "failed: " + (CloudCredentialTransfer.Failure.deliveryFailed.errorDescription ?? ""))
        #expect(outcome != CloudStartChat.loginCancelled)
    }

    @Test func anyErrorTheCancellationCausedIsCancelled() {
        #expect(CloudStartChat.cancelledLogin(CancellationError(), cancelled: false))
        #expect(CloudStartChat.cancelledLogin(URLError(.cancelled), cancelled: true))
        #expect(!CloudStartChat.cancelledLogin(URLError(.timedOut), cancelled: false))
    }
}
