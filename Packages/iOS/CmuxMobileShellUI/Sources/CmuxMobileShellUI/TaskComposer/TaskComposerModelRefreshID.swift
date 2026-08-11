#if os(iOS)
import CmuxMobileShellModel

/// Stable owner of one provider/Mac model request.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
}

/// Foreground connection state observed independently from request ownership.
struct TaskComposerModelConnectionSnapshot: Hashable {
    let macDeviceID: String?
    let instanceTag: String?

    func matchesSelectedMac(
        macDeviceID selectedMacDeviceID: String,
        instanceTag selectedMacInstanceTag: String?
    ) -> Bool {
        guard macDeviceID == selectedMacDeviceID else { return false }
        return selectedMacInstanceTag == nil
            || instanceTag == selectedMacInstanceTag
    }
}
#endif
