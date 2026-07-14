#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension TaskComposerSheet {
    var directorySection: some View {
        Section(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory")) {
            Button {
                isDirectoryPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(directory)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submissionPhase.disablesRequestEditing)
            .accessibilityLabel(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
            .accessibilityValue(directory)
            .accessibilityHint(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.hint",
                    defaultValue: "Opens a searchable list of folders from this Mac."
                )
            )
            .accessibilityIdentifier("MobileTaskComposerDirectory")
        }
    }

    var directoryCandidates: [MobileTaskDirectoryCandidate] {
        TaskComposerDirectoryCandidates(
            store: store,
            selectedMacDeviceID: selectedMacDeviceID,
            selectedTemplate: selectedTemplate
        ).make()
    }

    func selectDirectory(_ path: String) {
        guard !submissionPhase.disablesRequestEditing else { return }
        updateSubmissionRequest {
            directory = path
            didEditDirectory = true
        }
        failureText = nil
    }
}
#endif
