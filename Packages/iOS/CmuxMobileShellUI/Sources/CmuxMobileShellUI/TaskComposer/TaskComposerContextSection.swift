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
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}
#endif
