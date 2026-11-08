#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// The composer's workspace name, Mac, group, and directory controls.
struct TaskComposerOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

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
    let directoryCandidates: [MobileTaskDirectoryCandidate]
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String, String?) -> Void
    let selectWorkspaceGroup: (MobileWorkspaceGroupPreview.ID?) -> Void
    let selectDirectory: (String) -> Void
    let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
    let listMac: (
        _ path: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>

    @State private var isDirectoryPickerPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                TaskComposerContextSection(
                    workspaceName: $workspaceName,
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
                    endWorkspaceNameEditing: endWorkspaceNameEditing,
                    selectMachine: selectMachine,
                    selectWorkspaceGroup: selectWorkspaceGroup,
                    selectDirectory: { isDirectoryPickerPresented = true }
                )
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
            }
            .navigationTitle(L10n.string(
                "mobile.taskComposer.options.title",
                defaultValue: "Task Options"
            ))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileTaskComposerOptionsDoneButton")
                }
            }
            .sheet(isPresented: $isDirectoryPickerPresented) {
                TaskComposerDirectoryPickerView(
                    candidates: directoryCandidates,
                    selectedPath: directory,
                    select: selectDirectory,
                    searchMac: searchMac,
                    listMac: listMac
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif
