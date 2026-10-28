@testable import CmuxNextApp
import CmuxNextCredentialVault
import CmuxNextDesign
import Testing

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.dialog` (Debug builds) never answers the Credential Vault's sheet for the person and
/// never reports what is typed in a hidden field (cmux issue 26412).
@MainActor struct CredentialVaultDebugDialogTests {
    @Test func theVaultSheetAnswersOnlyToThePersonAndItsValueIsNeverReported() {
        #expect(DebugDialog.userOnly.isSuperset(of: [CredentialVault.entrySheetIdentifier, CredentialVault.approvalSheetIdentifier,
                                                     CredentialVaultPageRoute.deleteDialogIdentifier]),
                "an agent's `cmux vault` cannot approve itself through debug.dialog")
        let spec = CredentialVault.entrySheet(.init(name: "GH_TOKEN", reason: nil, requester: "the Chief", replaces: false))
        #expect(DebugDialog.secureFields(spec) == [CredentialVault.entryValueField])
    }
}
#endif
