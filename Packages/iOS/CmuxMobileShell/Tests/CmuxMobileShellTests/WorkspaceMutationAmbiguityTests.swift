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
@Test func reconciledTimeoutReportsUnknownResultWithLatestStateLoaded() {
    let store = MobileShellComposite.preview()

    #expect(store.reconciledWorkspaceMutationFailure(
        MobileShellConnectionError.requestTimedOut,
        hostDisplayName: "Studio"
    ) == .resultUnknownRefreshed(hostDisplayName: "Studio"))
}

@MainActor
@Test func rejectedMutationDispositionDistinguishesRetryableStateFromPolicy() {
    let store = MobileShellComposite.preview()

    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("protected", "Protected")
    ) == .definiteDivergence)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("unavailable", "Unavailable")
    ) == .definiteDivergence)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("result_unknown", "Mutation result is unknown")
    ) == .ambiguous)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("confirmation_required", "Confirm")
    ) == .immediateRejection)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("not_found", "Missing")
    ) == .definiteDivergence)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.rpcError("rejected", "Rejected")
    ) == .definiteDivergence)
    #expect(store.workspaceMutationErrorDisposition(
        MobileShellConnectionError.requestTimedOut
    ) == .ambiguous)
}
