#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Immutable per-computer snapshot for the Computers screen. Holds no
/// `@Observable` store, so the row sits safely below the screen's `List`
/// boundary (see AGENTS.md snapshot-boundary rule). Built from the device
/// registry / paired-Mac fallback plus presence and the live connection status.
struct MacComputerSnapshot: Equatable, Identifiable {
    let deviceId: String
    let title: String
    let platform: String
    /// The Mac's distinct color index (matches its workspaces' avatar color in the
    /// list). `nil` falls back to a hash of the device id.
    var colorIndex: Int?
    let lastSeenAt: Date
    /// How many aggregated workspaces this computer currently contributes.
    let workspaceCount: Int
    /// Whether the live foreground connection currently targets this computer.
    let isConnected: Bool
    /// The live connection status, present only for the connected computer.
    let liveStatus: MobileMacConnectionStatus?
    /// Live presence (online / offline+lastSeen) from the heartbeat service.
    let presence: DeviceTreePresence?

    var id: String { deviceId }
}

/// A computer (Mac/host) row on the Computers screen: a machine-colored avatar
/// (same color the computer's workspaces use in the list), its name, an
/// online/last-seen status line with workspace count, and a trailing liveness
/// badge. Remove/management actions are attached by the list via swipe and
/// context menu, not held in the row.
struct MacComputerRow: View {
    let computer: MacComputerSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: platformSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(computer.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            badge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileComputerRow-\(computer.deviceId)")
    }

    @ViewBuilder
    private var badge: some View {
        if let liveStatus = computer.liveStatus {
            Image(systemName: liveStatus.symbolName)
                .foregroundStyle(liveStatus.tintColor)
                .accessibilityLabel(liveStatus.label)
        } else {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(isOnline ? Color.green : Color.secondary.opacity(0.5))
                .accessibilityLabel(isOnline
                    ? L10n.string("mobile.deviceTree.online", defaultValue: "Online")
                    : L10n.string("mobile.deviceTree.offline", defaultValue: "Offline"))
        }
    }

    private var avatarGradient: LinearGradient {
        if let colorIndex = computer.colorIndex {
            return MachineAvatarColors.gradient(index: colorIndex)
        }
        return MachineAvatarColors.gradient(machineID: computer.deviceId, fallbackID: computer.deviceId)
    }

    private var isOnline: Bool {
        if computer.isConnected { return computer.liveStatus == .connected }
        if case .online = computer.presence { return true }
        return false
    }

    private var platformSymbol: String {
        switch computer.platform.lowercased() {
        case "linux", "windows": return "server.rack"
        default: return "desktopcomputer"
        }
    }

    /// "<status> · <N workspaces>" — the liveness phrase followed by the
    /// computer's contribution to the aggregated list.
    private var detailLine: String {
        let count = L10n.terminalCountWorkspaces(computer.workspaceCount)
        return "\(statusPhrase) · \(count)"
    }

    private var statusPhrase: String {
        if let liveStatus = computer.liveStatus {
            return liveStatus.label
        }
        switch computer.presence {
        case .online:
            return L10n.string("mobile.deviceTree.online", defaultValue: "Online")
        case .offline(let lastSeenAt):
            return lastSeenLine(max(lastSeenAt, computer.lastSeenAt))
        case nil:
            return lastSeenLine(computer.lastSeenAt)
        }
    }

    private func lastSeenLine(_ lastSeenAt: Date) -> String {
        String(
            format: L10n.string("mobile.deviceTree.lastSeenFormat", defaultValue: "Last seen %@"),
            lastSeenAt.formatted(.relative(presentation: .named))
        )
    }
}
#endif
