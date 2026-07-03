import CmuxMobileShell
import CmuxMobileShellModel

extension CMUXMobileRootView {
    func showManualHostTrustWarningIfNeeded(
        _ warning: MobileManualHostTrustWarning? = nil
    ) {
        guard warning ?? store.manualHostTrustWarning != nil else {
            return
        }
        showAddDevice()
    }

    func acceptPairingVersionWarning() async {
        let result = await store.acceptPairingVersionWarning()
        clearAttachTicketAuthentication(after: result)
        if result == .connected {
            dismissAddDeviceSheet()
        }
    }

    func acceptManualHostTrustWarning() async {
        let result = await store.acceptManualHostTrustWarning()
        clearAttachTicketAuthentication(after: result)
        if result == .connected {
            dismissAddDeviceSheet()
        }
    }
}
