#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileSettingsDeleteAccountFailureKindTests {
    @Test func cleanupIncompleteSignsOutAfterAcknowledgementOnly() {
        #expect(DeleteAccountFailureKind.serverCleanupIncomplete.signsOutAfterAcknowledgement)
        #expect(!DeleteAccountFailureKind.generic.signsOutAfterAcknowledgement)
        #expect(!DeleteAccountFailureKind.connection.signsOutAfterAcknowledgement)
        #expect(!DeleteAccountFailureKind.stackDeleteIncomplete.signsOutAfterAcknowledgement)
        #expect(!DeleteAccountFailureKind.timedOut.signsOutAfterAcknowledgement)
        #expect(!DeleteAccountFailureKind.unknown.signsOutAfterAcknowledgement)
    }
}
#endif
