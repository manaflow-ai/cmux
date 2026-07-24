#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShellModel
import SwiftUI

/// Groups the optional workspace title with the Mac and directory that define
/// where the task will run.
struct TaskComposerContextSection: View {
    @Binding var workspaceName: String
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let modelPickerVariant: TaskComposerModelPickerVariant
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isDisabled: Bool
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String) -> Void
    let selectDirectory: () -> Void
    let selectModel: (String?) -> Void

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
                selectedMacDeviceID: selectedMacDeviceID,
                directory: directory,
                isDisabled: isDisabled,
                selectMachine: selectMachine,
                selectDirectory: selectDirectory
            )

            if !models.isEmpty,
               modelPickerVariant.renderedVariant == .contextRow {
                Divider()
                    .padding(.horizontal, 10)

                TaskComposerModelContextRow(
                    models: models,
                    selectedModelID: selectedModelID,
                    isDisabled: isDisabled,
                    selectModel: selectModel
                )
            }
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
