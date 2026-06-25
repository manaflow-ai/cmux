#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceComputerStripItem: View {
    let computer: MacComputerSnapshot
    let isSelected: Bool
    let selectComputer: () -> Void
    let createWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: selectComputer) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(avatarGradient)
                            .frame(width: 54, height: 54)
                            .overlay(selectionRing)
                        avatarIcon
                        Circle()
                            .fill(statusColor)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 2))
                            .offset(x: -3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(itemAccessibilityLabel)
                .accessibilityIdentifier("MobileWorkspaceComputerStripItem-\(computer.deviceId)")

                Button(action: createWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -5)
                .accessibilityLabel(String(
                    format: L10n.string(
                        "mobile.workspaces.computerStrip.newWorkspaceFormat",
                        defaultValue: "New workspace on %@"
                    ),
                    computer.title
                ))
                .accessibilityIdentifier("MobileWorkspaceComputerStripNew-\(computer.deviceId)")
            }
            Text(computer.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 84)
        }
    }

    private var itemAccessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.workspaces.computerStrip.itemAccessibilityFormat",
                defaultValue: "%@, %@"
            ),
            computer.title,
            statusLabel
        )
    }

    private var selectionRing: some View {
        Circle()
            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
    }

    @ViewBuilder
    private var avatarIcon: some View {
        switch MacAvatarIcon.resolve(custom: computer.customIcon, defaultSymbol: "desktopcomputer") {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: 24))
        }
    }

    private var avatarGradient: LinearGradient {
        MachineAvatarColors.gradient(
            customColor: computer.customColor,
            fallbackIndex: computer.colorIndex,
            machineID: computer.deviceId,
            fallbackID: computer.deviceId
        )
    }

    private var statusColor: Color {
        switch computer.connectionStatus {
        case .connected:
            return .green
        case .reconnecting:
            return .orange
        case .unavailable, nil:
            return .red
        }
    }

    private var statusLabel: String {
        switch computer.connectionStatus {
        case .connected:
            return L10n.string("mobile.deviceTree.connected", defaultValue: "Connected")
        case .reconnecting:
            return L10n.string("mobile.deviceTree.reconnecting", defaultValue: "Reconnecting…")
        case .unavailable, nil:
            return L10n.string("mobile.computers.notConnected", defaultValue: "Not connected")
        }
    }
}
#endif
