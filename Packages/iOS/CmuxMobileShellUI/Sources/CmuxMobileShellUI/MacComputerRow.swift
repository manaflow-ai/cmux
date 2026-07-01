#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// A computer (Mac/host) row on the Computers screen: a machine-colored avatar,
/// the Mac's name, a primary line for the PHONE'S connection state + workspace
/// count, and a diagnostic line for presence + route. The trailing dot reflects
/// the phone's connection (green = the phone is talking to this Mac now).
struct MacComputerRow: View {
    let computer: MacComputerSnapshot
    /// Request confirmation before removing this computer. When `nil`, the
    /// destructive affordances are hidden.
    var requestRemove: ((String) -> Void)? = nil
    /// Whether this row's destructive remove action is awaiting confirmation.
    /// The binding is owned by the list so recycled rows do not own presentation
    /// state, but the presenter stays attached to the swiped row.
    var isConfirmingRemove: Binding<Bool> = .constant(false)
    /// Performs the confirmed removal. Separate from ``requestRemove`` so a
    /// full-swipe can request confirmation without directly removing the row.
    var confirmRemove: ((String) -> Void)? = nil

    var body: some View {
        NavigationLink(value: computer.deviceId) {
            rowLabel
        }
        .contextMenu { removeMenuButton }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            removeSwipeButton
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileComputerRow-\(computer.deviceId)")
        .confirmationDialog(
            removeTitle,
            isPresented: isConfirmingRemove,
            titleVisibility: .visible
        ) {
            if let confirmRemove {
                Button(
                    L10n.string("mobile.computers.remove", defaultValue: "Remove"),
                    role: .destructive
                ) {
                    confirmRemove(computer.deviceId)
                }
                .accessibilityIdentifier("MobileComputerRemoveConfirm-\(computer.deviceId)")
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isConfirmingRemove.wrappedValue = false
            }
        } message: {
            Text(removeMessage)
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 40, height: 40)
                switch MacAvatarIcon.resolve(custom: computer.customIcon, defaultSymbol: platformSymbol) {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                case .emoji(let emoji):
                    Text(emoji).font(.system(size: 20)).accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(computer.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let buildLabel = computer.buildLabel {
                        buildBadge(buildLabel)
                    }
                    if let transportLabel {
                        transportBadge(transportLabel)
                    }
                }
                Text(connectionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(diagnosticLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            badge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var removeSwipeButton: some View {
        if let requestRemove {
            Button {
                requestRemove(computer.deviceId)
            } label: {
                Label(
                    L10n.string("mobile.computers.remove", defaultValue: "Remove"),
                    systemImage: "trash"
                )
            }
            .tint(.red)
            .accessibilityIdentifier("MobileComputerRemoveSwipeButton-\(computer.deviceId)")
        }
    }

    @ViewBuilder
    private var removeMenuButton: some View {
        if let requestRemove {
            Button(role: .destructive) {
                requestRemove(computer.deviceId)
            } label: {
                Label(
                    L10n.string("mobile.computers.remove", defaultValue: "Remove"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier("MobileComputerRemoveMenuButton-\(computer.deviceId)")
        }
    }

    private var removeTitle: String {
        String(
            format: L10n.string("mobile.computers.removeTitleFormat", defaultValue: "Remove %@?"),
            computer.title
        )
    }

    private var removeMessage: String {
        guard computer.aliasIDs.count > 1 else {
            return L10n.string(
                "mobile.computers.removeMessage",
                defaultValue: "This computer and its workspaces stop appearing here. Pair it again to add it back."
            )
        }
        return L10n.string(
            "mobile.computers.removeMessageRepresentativeFormat",
            defaultValue: "This removes this computer and its matching paired records. Its workspaces stop appearing here. Pair it again to add it back."
        )
    }

    /// The connection dot: green only when the PHONE is actually connected to this
    /// Mac. Orange while reconnecting, grey when the phone is not connected (even
    /// if presence says the Mac is online — that's the route/tailscale signal).
    @ViewBuilder
    private var badge: some View {
        Image(systemName: "circle.fill")
            .font(.caption2)
            .foregroundStyle(dotColor)
            .accessibilityLabel(connectionPhrase)
            .accessibilityIdentifier("MobileComputerStatus-\(computer.deviceId)-\(isConnected ? "connected" : "disconnected")")
    }

    /// A small build-channel pill (e.g. "DEV · teams", "Nightly"). DEV/RC/Staging
    /// are tinted orange (pre-release), Nightly blue, Stable secondary, so a glance
    /// tells you what kind of build a host runs.
    private func buildBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(buildBadgeTint(label).opacity(0.18), in: Capsule())
            .foregroundStyle(buildBadgeTint(label))
            .accessibilityLabel(
                "\(L10n.string("mobile.computers.buildLabelPrefix", defaultValue: "Build:")) \(label)")
    }

    private func buildBadgeTint(_ label: String) -> Color {
        if label.hasPrefix("DEV") || label == "RC" || label == "Staging" { return .orange }
        if label == "Nightly" { return .blue }
        return .secondary
    }

    /// The localized display label for the Mac-chosen transport mode, or `nil`
    /// when the host hasn't announced one (see ``MobileTransportModeLabel``).
    private var transportLabel: String? {
        MobileTransportModeLabel.label(for: computer.transportMode)
    }

    /// A read-only pill showing HOW this Mac is reachable (the Mac chooses the
    /// transport; the phone only displays it). Neutral tint: informational, not
    /// a state to act on from here — change it on the Mac.
    private func transportBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "\(L10n.string("mobile.computers.transportLabelPrefix", defaultValue: "Transport:")) \(label)")
            .accessibilityIdentifier("MobileComputerTransport-\(computer.deviceId)")
    }

    private var dotColor: Color {
        switch computer.connectionStatus {
        case .connected: return .green
        case .reconnecting: return .orange
        case .unavailable, nil: return .secondary.opacity(0.5)
        }
    }

    private var isConnected: Bool { computer.connectionStatus == .connected }

    private var avatarGradient: LinearGradient {
        MachineAvatarColors.gradient(
            customColor: computer.customColor,
            fallbackIndex: computer.colorIndex,
            machineID: computer.deviceId,
            fallbackID: computer.deviceId
        )
    }

    private var platformSymbol: String {
        switch computer.platform.lowercased() {
        case "linux", "windows": return "server.rack"
        default: return "desktopcomputer"
        }
    }

    /// Primary line: the phone's connection to this Mac + workspace count.
    private var connectionLine: String {
        let count = L10n.terminalCountWorkspaces(computer.workspaceCount)
        return "\(connectionPhrase) · \(count)"
    }

    private var connectionPhrase: String {
        switch computer.connectionStatus {
        case .connected:
            return L10n.string("mobile.deviceTree.connected", defaultValue: "Connected")
        case .reconnecting:
            return L10n.string("mobile.deviceTree.reconnecting", defaultValue: "Reconnecting…")
        case .unavailable, nil:
            return L10n.string("mobile.computers.notConnected", defaultValue: "Not connected")
        }
    }

    /// Diagnostic line: presence (the Mac's own heartbeat) + the route the phone
    /// would dial. Lets the user see "online via presence but phone not connected"
    /// (a tailscale/route problem) and the exact endpoint.
    ///
    /// When the phone is CONNECTED to this Mac, the live connection is the liveness
    /// truth, so a server "presence: unknown" next to "Connected" is contradictory
    /// noise — drop it and show just the route. Real presence data (online / last
    /// seen) still shows, and the full presence state is always in the detail sheet.
    private var diagnosticLine: String {
        let route = computer.routeDescription ?? L10n.string("mobile.computers.noRoute", defaultValue: "no route")
        if isConnected, computer.presence == nil {
            return route
        }
        return String(
            format: L10n.string("mobile.computers.diagnosticFormat", defaultValue: "Presence: %@ · %@"),
            presencePhrase, route
        )
    }

    private var presencePhrase: String {
        switch computer.presence {
        case .online:
            return L10n.string("mobile.deviceTree.online", defaultValue: "Online")
        case .offline(let lastSeenAt):
            return lastSeenLine(max(lastSeenAt, computer.lastSeenAt))
        case nil:
            return L10n.string("mobile.computers.presenceUnknown", defaultValue: "unknown")
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
