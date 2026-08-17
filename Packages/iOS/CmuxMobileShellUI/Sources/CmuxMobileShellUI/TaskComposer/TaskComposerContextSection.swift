#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShellModel
import SwiftUI

/// Groups the optional workspace title with the Mac, group, and directory that
/// define where the task will run.
struct TaskComposerContextSection: View {
    @Binding var workspaceName: String
    let machines: [MobilePairedMac]
    let selectedMacPairingID: String
    let buildLabelsByID: [String: String]
    let workspaceGroups: [MobileWorkspaceGroupPreview]
    let selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    let workspaceGroupSelectionPending: Bool
    let workspaceGroupSelectionRequiresResolution: Bool
    let showsWorkspaceGroupPicker: Bool
    let directory: String
    let isDisabled: Bool
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String, String?) -> Void
    let selectWorkspaceGroup: (MobileWorkspaceGroupPreview.ID?) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TaskComposerWorkspaceNameField(
                workspaceName: $workspaceName,
                isDisabled: isDisabled,
                endEditing: endWorkspaceNameEditing
            )
            .background(cardBackground, in: cardShape)

            TaskComposerRoutePicker(
                machines: machines,
                selectedMacPairingID: selectedMacPairingID,
                buildLabelsByID: buildLabelsByID,
                workspaceGroups: workspaceGroups,
                selectedWorkspaceGroupID: selectedWorkspaceGroupID,
                workspaceGroupSelectionPending: workspaceGroupSelectionPending,
                workspaceGroupSelectionRequiresResolution: workspaceGroupSelectionRequiresResolution,
                showsWorkspaceGroupPicker: showsWorkspaceGroupPicker,
                directory: directory,
                isDisabled: isDisabled,
                selectMachine: selectMachine,
                selectWorkspaceGroup: selectWorkspaceGroup,
                selectDirectory: selectDirectory
            )
            .background(cardBackground, in: cardShape)
        }
    }

    private var cardBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
}
#endif
