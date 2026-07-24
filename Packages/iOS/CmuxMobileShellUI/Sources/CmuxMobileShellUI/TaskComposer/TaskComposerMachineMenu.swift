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
        ZStack {
            TaskComposerRouteLabel(
                icon: selectedMachine.map(routeIconContent(for:)) ?? .symbol("desktopcomputer"),
                title: L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"),
                value: selectedMachine?.resolvedName ?? value.selectedMacDeviceID,
                valueFont: .caption.weight(.semibold),
                valueTruncationMode: .tail,
                chevronSystemName: "chevron.up.chevron.down"
            )
            .accessibilityHidden(true)

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
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .disabled(value.isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
        .accessibilityValue(selectedMachine?.resolvedName ?? value.selectedMacDeviceID)
        .accessibilityHint(TaskComposerSheet.machineAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerMachineMenu")
    }

    private func routeIconContent(for mac: MobilePairedMac) -> TaskComposerRouteIcon.Content {
        switch MacAvatarIcon.resolve(custom: mac.customIcon, defaultSymbol: "desktopcomputer") {
        case .symbol(let name):
            .symbol(name)
        case .emoji(let emoji):
            .emoji(emoji)
        }
    }
}
#endif
