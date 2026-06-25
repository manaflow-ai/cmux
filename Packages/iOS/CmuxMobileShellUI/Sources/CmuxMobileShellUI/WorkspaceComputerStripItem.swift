#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceComputerStripItem: View {
    let computer: MacComputerSnapshot
    let isSelected: Bool
    let createWorkspace: () -> Void
    let manageComputer: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: createWorkspace) {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(newWorkspaceAccessibilityLabel)
            .accessibilityHint(itemAccessibilityHint)
            .accessibilityIdentifier("MobileWorkspaceComputerStripItem-\(computer.deviceId)")
            .accessibilityAction(
                named: Text(L10n.string("mobile.computers.manage", defaultValue: "Manage Computer")),
                manageComputer
            )
            .onLongPressGesture(minimumDuration: 0.45, perform: manageComputer)

            Text(computer.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(avatarGradient)
            .frame(width: 54, height: 54)
            .overlay(selectionRing)
            .overlay(alignment: .center) {
                avatarIcon
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 2))
                    .offset(x: -3, y: -3)
                    .accessibilityHidden(true)
            }
            .contentShape(Circle())
    }

    private var newWorkspaceAccessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.workspaces.computerStrip.newWorkspaceFormat",
                defaultValue: "New workspace on %@"
            ),
            computer.title
        )
    }

    private var itemAccessibilityHint: String {
        String(
            format: L10n.string(
                "mobile.workspaces.computerStrip.itemAccessibilityHintFormat",
                defaultValue: "%@. Touch and hold to manage this computer."
            ),
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
        case .reconnecting, .unavailable, nil:
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
