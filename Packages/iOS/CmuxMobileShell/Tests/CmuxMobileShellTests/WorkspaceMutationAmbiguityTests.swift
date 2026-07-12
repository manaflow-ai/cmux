import CmuxMobileRPC
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func unreconciledTimeoutReportsUnknownResultInsteadOfApplied() {
    let store = MobileShellComposite.preview()

    #expect(store.unreconciledWorkspaceMutationFailure(
        MobileShellConnectionError.requestTimedOut,
        hostDisplayName: "Studio"
    ) == .resultUnknownNeedsRefresh(hostDisplayName: "Studio"))
}

@MainActor
@Test func unreconciledRejectedMutationPreservesDefiniteFailure() {
    let store = MobileShellComposite.preview()

    #expect(store.unreconciledWorkspaceMutationFailure(
        MobileShellConnectionError.rpcError("rejected", "Rejected"),
        hostDisplayName: "Studio"
    ) == .rejected(hostDisplayName: "Studio"))
}
