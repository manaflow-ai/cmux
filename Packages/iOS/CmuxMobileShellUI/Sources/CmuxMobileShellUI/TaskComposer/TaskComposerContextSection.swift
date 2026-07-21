#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

/// Keeps the Mac and folder on one compact route so both remain visible while typing.
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 5)
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
                HStack(spacing: 8) {
                    if let selectedMachine {
                        machineIcon(selectedMachine)
                    } else {
                        contextSymbol("desktopcomputer", tint: .accentColor)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(selectedMachine?.resolvedName ?? selectedMacDeviceID)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
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
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
#endif
