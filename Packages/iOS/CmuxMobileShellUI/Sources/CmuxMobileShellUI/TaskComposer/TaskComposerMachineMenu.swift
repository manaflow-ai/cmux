#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileSupport
import SwiftUI

struct TaskComposerMachineMenu: View, Equatable {
    let value: TaskComposerMachineMenuValue
    let actions: TaskComposerMachineMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    private var selectedMachine: MobilePairedMac? {
        value.machines.first { $0.macDeviceID == value.selectedMacDeviceID }
    }

    var body: some View {
        Menu {
            ForEach(value.machines) { mac in
                Button {
                    actions.selectMachine(mac.macDeviceID)
                } label: {
                    Label(mac.resolvedName, systemImage: "desktopcomputer")
                }
                .accessibilityAddTraits(mac.macDeviceID == value.selectedMacDeviceID ? .isSelected : [])
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
                    Text(selectedMachine?.resolvedName ?? value.selectedMacDeviceID)
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
        .disabled(value.isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
        .accessibilityValue(selectedMachine?.resolvedName ?? value.selectedMacDeviceID)
        .accessibilityHint(TaskComposerSheet.machineAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerMachineMenu")
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
