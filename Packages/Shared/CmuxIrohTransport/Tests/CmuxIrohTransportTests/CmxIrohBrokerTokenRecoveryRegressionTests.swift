import Foundation
import Testing

@testable import CmuxIrohTransport

/// Regression coverage for the host-auth recovery seam. A platform auth owner
/// must be able to report a definitive refresh rejection to its lifecycle
/// owner instead of having ``accountPinned`` turn it into an indistinguishable
/// missing pair.
@Suite("broker token recovery regression")
struct CmxIrohBrokerTokenRecoveryRegressionTests {
    private enum RefreshFailure: Error, Equatable {
        case unauthorized
    }

    @Test("account-pinned recovery preserves a rejected refresh outcome")
    func accountPinnedPreservesRefreshFailure() async {
        let source = CmxIrohBrokerTokenSource.accountPinned(
            to: "account-a",
            snapshot: {
                CmxIrohAccountCredentialSnapshot(
                    accountID: "account-a",
                    credentials: CmxIrohBrokerCredentials(
                        accessToken: "stale-access",
                        refreshToken: "stale-refresh"
                    )
                )
            },
            forceRefresh: {
                throw RefreshFailure.unauthorized
            }
        )

        await #expect(throws: RefreshFailure.unauthorized) {
            _ = try await source.recoveredCredentialPair(
                CmxIrohBrokerCredentials(
                    accessToken: "stale-access",
                    refreshToken: "stale-refresh"
                )
            )
        }
    }
}
