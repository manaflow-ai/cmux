#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

struct TaskComposerRoutePicker: View {
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let isDisabled: Bool
    let selectMachine: (String) -> Void
    let selectDirectory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            machinePicker

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
                contextSymbol("desktopcomputer.trianglebadge.exclamationmark", tint: .accentColor)
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
