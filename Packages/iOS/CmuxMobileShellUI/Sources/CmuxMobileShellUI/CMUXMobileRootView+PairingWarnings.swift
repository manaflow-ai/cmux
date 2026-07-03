import CmuxMobileShell

extension CMUXMobileRootView {
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
