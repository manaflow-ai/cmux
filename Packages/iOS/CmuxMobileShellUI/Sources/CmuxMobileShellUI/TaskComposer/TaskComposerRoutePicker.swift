#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskComposerRoutePicker: View {
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
    let selectMachine: (String, String?) -> Void
    let selectWorkspaceGroup: (MobileWorkspaceGroupPreview.ID?) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            machinePicker

            routeDivider

            directoryPicker

            if showsWorkspaceGroupPicker {
                routeDivider

                TaskComposerWorkspaceGroupMenu(
                    groups: workspaceGroups,
                    selectedWorkspaceGroupID: selectedWorkspaceGroupID,
                    isSelectionPending: workspaceGroupSelectionPending,
                    requiresSelectionResolution: workspaceGroupSelectionRequiresResolution,
                    isDisabled: isDisabled,
                    select: selectWorkspaceGroup
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var routeDivider: some View {
        Divider()
            .padding(.leading, 58)
    }

    private var directoryPicker: some View {
        Button(action: selectDirectory) {
            TaskComposerRouteLabel(
                icon: .symbol("folder.fill"),
                title: L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"),
                value: directory,
                valueFont: .system(.caption, design: .monospaced, weight: .semibold),
                valueTruncationMode: .middle,
                chevronSystemName: "chevron.right"
            )
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

    @ViewBuilder
    private var machinePicker: some View {
        if machines.isEmpty {
            HStack(spacing: 8) {
                TaskComposerRouteIcon(content: .symbol("desktopcomputer.trianglebadge.exclamationmark"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.taskComposer.machine.none", defaultValue: "No paired Macs"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        } else {
            TaskComposerMachineMenu(
                value: TaskComposerMachineMenuValue(
                    machines: machines,
                    selectedMacPairingID: selectedMacPairingID,
                    buildLabelsByID: buildLabelsByID,
                    isDisabled: isDisabled
                ),
                actions: TaskComposerMachineMenuActions(
                    selectMachine: selectMachine
                )
            )
            .equatable()
        }
    }
}
#endif
