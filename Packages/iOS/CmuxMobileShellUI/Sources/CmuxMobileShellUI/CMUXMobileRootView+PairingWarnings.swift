import CmuxMobileShell
import CmuxMobileShellModel

extension CMUXMobileRootView {
    func showManualHostTrustWarningIfNeeded(
        _ warning: MobileManualHostTrustWarning? = nil
    ) {
        guard warning ?? store.manualHostTrustWarning != nil,
              isAuthenticated,
              !authManager.isRestoringSession,
              !shouldShowOnboarding,
              !isShowingAddDeviceSheet else {
            return
        }
        showAddDevice()
    }

    func acceptPairingVersionWarning() async {
        let result = await store.acceptPairingVersionWarning()
        finishPairingPresentation(after: result)
    }

    func acceptManualHostTrustWarning() async {
        let result = await store.acceptManualHostTrustWarning()
        finishPairingPresentation(after: result)
    }

    func finishPairingPresentation(after result: MobilePairingURLConnectionResult) {
        clearAttachTicketAuthentication(after: result)
        switch result {
        case .connected:
            dismissAddDeviceSheet()
        case .needsUserApproval:
            showAddDevice()
        case .failed, .superseded:
            break
        }
    }
}
