@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocusUI
import Testing

/// One toast id per kind of result: every Cloud result used one id, so a success right after a
/// failure replaced the failure before it was read; and a refused workspace close and a refused tab
/// close used two ids, so one refusal could toast twice (error-states audit, 2026-11-12).
@MainActor @Suite struct CloudResultToastTests {
    @Test func aFailureKeepsItsOwnToast() {
        #expect(CloudPresenter.failureToastID != CloudPresenter.resultToastID)
    }

    @Test func everyRefusedCloseSharesTheRefusalToast() {
        #expect(RefusalHUD.toastID == CmuxToast.refusalID)
    }
}
