#if os(iOS)
import CmuxMobilePairedMac
import SwiftUI

/// Groups the optional workspace title with the Mac and directory that define
/// where the task will run.
struct TaskComposerContextSection: View {
    @Binding var workspaceName: String
    let machines: [MobilePairedMac]
    let selectedMacPairingID: String
    let buildLabelsByID: [String: String]
    let directory: String
    let isDisabled: Bool
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String, String?) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TaskComposerWorkspaceNameField(
                workspaceName: $workspaceName,
                isDisabled: isDisabled,
                endEditing: endWorkspaceNameEditing
            )

            Divider()
                .padding(.horizontal, 10)

            TaskComposerRoutePicker(
                machines: machines,
                selectedMacPairingID: selectedMacPairingID,
                buildLabelsByID: buildLabelsByID,
                directory: directory,
                isDisabled: isDisabled,
                selectMachine: selectMachine,
                selectDirectory: selectDirectory
            )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 5)
    }
}
#endif
