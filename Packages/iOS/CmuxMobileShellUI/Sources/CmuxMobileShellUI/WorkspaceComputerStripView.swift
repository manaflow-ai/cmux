#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceComputerStripView: View {
    let computers: [MacComputerSnapshot]
    let selectedMachineIDs: Set<String>
    let createWorkspace: (MacComputerSnapshot) -> Void
    let manageComputer: (MacComputerSnapshot) -> Void
    let removeComputer: (MacComputerSnapshot) -> Void
    var showAddDevice: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(computers) { computer in
                    WorkspaceComputerStripItem(
                        computer: computer,
                        isSelected: !selectedMachineIDs.isDisjoint(with: computer.aliasIDSet),
                        createWorkspace: { createWorkspace(computer) },
                        manageComputer: { manageComputer(computer) },
                        removeComputer: { removeComputer(computer) }
                    )
                }
                if let showAddDevice {
                    addComputerItem(showAddDevice)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: 104)
        .accessibilityIdentifier("MobileWorkspaceComputerStrip")
    }

    private func addComputerItem(_ showAddDevice: @escaping () -> Void) -> some View {
        Button(action: showAddDevice) {
            VStack(spacing: 6) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Circle().fill(Color.secondary.opacity(0.10)))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                Text(L10n.string("mobile.computers.add", defaultValue: "Add Computer"))
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 70, height: 28, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileWorkspaceComputerStripAdd")
    }
}

private extension MacComputerSnapshot {
    var aliasIDSet: Set<String> {
        var ids = Set(aliasIDs)
        ids.insert(deviceId)
        return ids
    }
}
#endif
