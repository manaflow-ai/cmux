#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

struct TaskComposerRoutePicker: View {
    let machines: [MobilePairedMac]
    let selectedMacPairingID: String
    let buildLabelsByID: [String: String]
    let directory: String
    let isDisabled: Bool
    let selectMachine: (String, String?) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            machinePicker

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
        .padding(10)
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
