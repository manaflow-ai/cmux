#if os(iOS)
import CmuxMobilePairedMac

struct TaskComposerMachineMenuValue: Equatable {
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let isDisabled: Bool
}
#endif
