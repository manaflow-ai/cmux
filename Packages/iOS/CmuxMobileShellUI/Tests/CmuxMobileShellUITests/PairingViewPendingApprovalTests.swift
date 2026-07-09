import CmuxMobileShellModel
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct PairingViewPendingApprovalTests {
    @MainActor
    @Test func pairClearsPendingManualHostApprovalBeforeLocalValidationReturns() {
        var cancelCount = 0
        let view = PairingView(
            pairingCode: .constant(""),
            connectionError: nil,
            connectionErrorGuidance: nil,
            versionWarning: nil,
            manualHostTrustWarning: warning(),
            connectPairingCode: {},
            acceptVersionWarning: {},
            acceptManualHostTrustWarning: {},
            connectManualHost: { _, _, _ in },
            cancelPairing: { cancelCount += 1 },
            cancel: {}
        )

        view.pair()

        #expect(cancelCount == 1)
    }

    private func warning() -> MobileManualHostTrustWarning {
        let scope = MobileManualHostTrustScope(
            host: "192.168.1.77",
            port: 58_465,
            stackUserID: "user_123"
        )!
        return MobileManualHostTrustWarning(scope: scope)
    }
}
