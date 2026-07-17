#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

/// Summarizes where the new workspace will run, with both choices one tap away.
struct TaskComposerContextSection: View {
    let machines: [MobilePairedMac]
    let selectedMacDeviceID: String
    let directory: String
    let isDisabled: Bool
    let selectMachine: (MobilePairedMac) -> Void
    let selectDirectory: () -> Void

    private var selectedMachine: MobilePairedMac? {
        machines.first { $0.macDeviceID == selectedMacDeviceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("mobile.taskComposer.workspace", defaultValue: "Workspace"))
                .font(.headline)

            VStack(spacing: 0) {
                machinePicker

                Divider()
                    .padding(.leading, 54)

                Button(action: selectDirectory) {
                    HStack(spacing: 12) {
                        contextSymbol("folder.fill", tint: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(directory)
                                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
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
            .padding(.horizontal, 14)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.075), lineWidth: 1)
            }
        }
        .accessibilityIdentifier("MobileTaskComposerWorkspaceContext")
    }

    @ViewBuilder
    private var machinePicker: some View {
        if machines.isEmpty {
            HStack(spacing: 12) {
                contextSymbol("desktopcomputer.trianglebadge.exclamationmark", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.taskComposer.machine.none", defaultValue: "No paired Macs"))
                        .font(.subheadline.weight(.medium))
                    Text(
                        L10n.string(
                            "mobile.taskComposer.validation.machine",
                            defaultValue: "Pair a Mac before starting a task."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .frame(minHeight: 58)
        } else {
            Menu {
                ForEach(machines) { mac in
                    Button {
                        selectMachine(mac)
                    } label: {
                        Label(mac.resolvedName, systemImage: "desktopcomputer")
                    }
                    .accessibilityAddTraits(mac.macDeviceID == selectedMacDeviceID ? .isSelected : [])
                }
            } label: {
                HStack(spacing: 12) {
                    if let selectedMachine {
                        machineIcon(selectedMachine)
                    } else {
                        contextSymbol("desktopcomputer", tint: .accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedMachine?.resolvedName ?? selectedMacDeviceID)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 58)
                .contentShape(Rectangle())
            }
            .disabled(isDisabled)
            .accessibilityLabel(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
            .accessibilityValue(selectedMachine?.resolvedName ?? selectedMacDeviceID)
            .accessibilityHint(TaskComposerSheet.machineAccessibilityHint)
            .accessibilityIdentifier("MobileTaskComposerMachineMenu")
        }
    }

    private func contextSymbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private func machineIcon(_ mac: MobilePairedMac) -> some View {
        ZStack {
            Circle()
                .fill(
                    MachineAvatarColors.gradient(
                        customColor: mac.customColor,
                        fallbackIndex: nil,
                        machineID: mac.macDeviceID,
                        fallbackID: mac.id
                    )
                )
            switch MacAvatarIcon.resolve(custom: mac.customIcon, defaultSymbol: "desktopcomputer") {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: 17))
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}
#endif
