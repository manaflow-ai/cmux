import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileMacConnectionFailureKindTests {
    @Test func confirmedOfflinePresenceUsesOfflineCopy() {
        #expect(MobileMacConnectionFailureKind.resolve(
            connectionStatus: .unavailable,
            presence: .offline
        ) == .knownOffline)
    }

    @Test(arguments: [MobileMacPresenceSignal.online, .unknown])
    func missingOfflineProofUsesGenericCopy(presence: MobileMacPresenceSignal) {
        #expect(MobileMacConnectionFailureKind.resolve(
            connectionStatus: .unavailable,
            presence: presence
        ) == .generic)
    }

    @Test func connectedMacHasNoFailurePresentation() {
        #expect(MobileMacConnectionFailureKind.resolve(
            connectionStatus: .connected,
            presence: .offline
        ) == nil)
    }
}
