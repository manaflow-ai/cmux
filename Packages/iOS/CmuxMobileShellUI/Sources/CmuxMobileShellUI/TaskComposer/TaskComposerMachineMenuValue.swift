#if os(iOS)
import CmuxMobilePairedMac

struct TaskComposerMachineMenuValue: Equatable {
    let machines: [MobilePairedMac]
    let selectedMacPairingID: String
    let buildLabelsByID: [String: String]
    let isDisabled: Bool

    var selectedMachine: MobilePairedMac? {
        machines.first(where: isSelected)
    }

    func isSelected(_ mac: MobilePairedMac) -> Bool {
        mac.id == selectedMacPairingID
    }
}
#endif
