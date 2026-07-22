#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

/// Groups the optional workspace title with the Mac and directory that define
/// where the task will run.
struct TaskComposerContextSection: View {
    @Binding var workspaceName: String
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let isDisabled: Bool
    let endWorkspaceNameEditing: () -> Void
    let selectMachine: (String) -> Void
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
                selectedMacDeviceID: selectedMacDeviceID,
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

private struct TaskComposerWorkspaceNameField: View {
    @Binding var workspaceName: String
    let isDisabled: Bool
    let endEditing: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
                .background(Color.indigo.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("mobile.taskComposer.workspaceName", defaultValue: "Workspace name"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(
                    L10n.string(
                        "mobile.taskComposer.workspaceName.generatedPlaceholder",
                        defaultValue: "Generated from prompt"
                    ),
                    text: $workspaceName
                )
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isFocused)
                .disabled(isDisabled)
                .accessibilityLabel(
                    L10n.string(
                        "mobile.taskComposer.workspaceName",
                        defaultValue: "Workspace name"
                    )
                )
                .accessibilityIdentifier("MobileTaskComposerWorkspaceName")
                .onSubmit(endEditing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: isFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                endEditing()
            }
        }
    }
}

private struct TaskComposerRoutePicker: View {
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let isDisabled: Bool
    let selectMachine: (String) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            machinePicker

            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.11), in: Circle())
                .accessibilityHidden(true)

            Button(action: selectDirectory) {
                HStack(spacing: 8) {
                    contextSymbol("folder.fill", tint: .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(directory)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
            .accessibilityValue(directory)
            .accessibilityHint(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.hint",
                    defaultValue: "Browses and searches folders on this Mac."
                )
            )
            .accessibilityIdentifier("MobileTaskComposerDirectory")
        }
        .padding(10)
    }

    @ViewBuilder
    private var machinePicker: some View {
        if machines.isEmpty {
            HStack(spacing: 8) {
                contextSymbol("desktopcomputer.trianglebadge.exclamationmark", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.taskComposer.machine.none", defaultValue: "No paired Macs"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        } else {
            TaskComposerMachineMenu(
                value: TaskComposerMachineMenuValue(
                    machines: machines,
                    selectedMacDeviceID: selectedMacDeviceID,
                    isDisabled: isDisabled
                ),
                actions: TaskComposerMachineMenuActions(
                    selectMachine: selectMachine
                )
            )
            .equatable()
        }
    }

    private func contextSymbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

}
#endif
