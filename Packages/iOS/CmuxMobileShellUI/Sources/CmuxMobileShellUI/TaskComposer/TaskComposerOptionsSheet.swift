#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// The minimal composer's workspace, Mac, directory, and contextual model controls.
struct TaskComposerOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var workspaceName: String
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let modelPickerVariant: TaskComposerModelPickerVariant
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isDisabled: Bool
    let directoryCandidates: [MobileTaskDirectoryCandidate]
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String) -> Void
    let selectDirectory: (String) -> Void
    let selectModel: (String?) -> Void
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
                    selectedMacDeviceID: selectedMacDeviceID,
                    directory: directory,
                    modelPickerVariant: modelPickerVariant,
                    models: models,
                    selectedModelID: selectedModelID,
                    isDisabled: isDisabled,
                    endWorkspaceNameEditing: endWorkspaceNameEditing,
                    selectMachine: selectMachine,
                    selectDirectory: { isDirectoryPickerPresented = true },
                    selectModel: selectModel
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
