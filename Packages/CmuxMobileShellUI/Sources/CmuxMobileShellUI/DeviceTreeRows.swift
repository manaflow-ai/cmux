#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

// Value snapshots + closure actions for the device tree rows. Nothing here holds
// an `@Observable` store, so these rows sit safely below the tree's `List`
// boundary (see AGENTS.md snapshot-boundary rule).

/// Live presence for a device row, rolled up from the presence service's
/// per-instance heartbeats (device online = any instance online). `nil` when
/// the presence service has no record of the device, in which case the row
/// falls back to its registry "last seen" hint.
enum DeviceTreePresence: Equatable {
    case online
    case offline(lastSeenAt: Date)
}

/// Immutable per-device snapshot for the device (top-level) row.
struct DeviceTreeDeviceSnapshot: Equatable {
    let deviceId: String
    let title: String
    let platform: String
    let lastSeenAt: Date
    let instanceCount: Int
    /// Whether the live connection currently targets this device.
    let isConnected: Bool
    /// The live connection status, present only for the connected device. `nil`
    /// for every other device, which is described by live presence (below) or
    /// its last-seen time.
    let liveStatus: MobileMacConnectionStatus?
    /// Live presence from the heartbeat service for non-connected devices.
    let presence: DeviceTreePresence?
}

/// Immutable per-instance snapshot for an app-instance (tag) row.
struct DeviceTreeInstanceSnapshot: Equatable {
    let tag: String
    let lastSeenAt: Date
    /// Whether this instance advertises at least one reachable route.
    let hasRoutes: Bool
    /// Workspaces visible under this instance (non-zero only for the active
    /// instance, since the registry carries routes, not workspaces).
    let workspaceCount: Int
    /// Whether this instance is the build the live connection currently targets
    /// (matched by route). Only the active instance shows live workspaces; other
    /// tags on the same device offer a Connect affordance.
    let isActiveInstance: Bool
}

/// A device (Mac/host) row: name, platform icon, and live-or-last-seen state,
/// with a disclosure chevron to reveal its tagged builds.
struct DeviceTreeDeviceRow: View {
    let device: DeviceTreeDeviceSnapshot
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void

    var body: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: chevronSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: platformSymbol)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.title)
                        .foregroundStyle(.primary)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let liveStatus = device.liveStatus {
                    Image(systemName: liveStatus.symbolName)
                        .foregroundStyle(liveStatus.tintColor)
                        .accessibilityLabel(liveStatus.label)
                } else if let presence = device.presence {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(presence == .online ? Color.green : Color.secondary.opacity(0.5))
                        .accessibilityLabel(presenceLabel(presence))
                        .accessibilityIdentifier(
                            "MobileDeviceTreePresence-\(device.deviceId)-\(presence == .online ? "online" : "offline")"
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileDeviceTreeDeviceRow-\(device.deviceId)")
        .accessibilityHint(
            isExpanded
                ? L10n.string("mobile.deviceTree.collapseHint", defaultValue: "Collapse builds")
                : L10n.string("mobile.deviceTree.expandHint", defaultValue: "Expand builds")
        )
    }

    private var chevronSymbol: String {
        isExpanded ? "chevron.down" : "chevron.right"
    }

    private var platformSymbol: String {
        switch device.platform.lowercased() {
        case "linux", "windows":
            return "server.rack"
        default:
            return "desktopcomputer"
        }
    }

    /// Live status text for the connected device, live presence for every
    /// other device the heartbeat service knows, otherwise the relative
    /// last-seen time as a best-effort liveness hint.
    private var statusLine: String {
        if let liveStatus = device.liveStatus {
            return liveStatus.label
        }
        switch device.presence {
        case .online:
            return L10n.string("mobile.deviceTree.online", defaultValue: "Online")
        case .offline(let lastSeenAt):
            // Presence heartbeats are usually fresher than the registry's
            // last registration write; show the most recent of the two.
            return lastSeenLine(max(lastSeenAt, device.lastSeenAt))
        case nil:
            return lastSeenLine(device.lastSeenAt)
        }
    }

    private func lastSeenLine(_ lastSeenAt: Date) -> String {
        String(
            format: L10n.string("mobile.deviceTree.lastSeenFormat", defaultValue: "Last seen %@"),
            lastSeenAt.formatted(.relative(presentation: .named))
        )
    }

    private func presenceLabel(_ presence: DeviceTreePresence) -> String {
        switch presence {
        case .online:
            return L10n.string("mobile.deviceTree.online", defaultValue: "Online")
        case .offline:
            return L10n.string("mobile.deviceTree.offline", defaultValue: "Offline")
        }
    }
}

/// An app-instance (tag) row under a device: the build tag, its workspace count
/// or connect affordance, with a disclosure chevron to reveal workspaces.
struct DeviceTreeInstanceRow: View {
    let instance: DeviceTreeInstanceSnapshot
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void
    /// Connect-on-tap for a non-connected instance, or `nil` when there is
    /// nothing to connect (already the live build, or no reachable route).
    let connect: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                setExpanded(!isExpanded)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instance.tag)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let connect {
                Button {
                    connect()
                } label: {
                    Text(L10n.string("mobile.deviceTree.connect", defaultValue: "Connect"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("MobileDeviceTreeConnect-\(instance.tag)")
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 12))
        .accessibilityIdentifier("MobileDeviceTreeInstanceRow-\(instance.tag)")
    }

    private var subtitle: String {
        if instance.isActiveInstance {
            return L10n.terminalCountWorkspaces(instance.workspaceCount)
        }
        if !instance.hasRoutes {
            return L10n.string("mobile.deviceTree.noRoutes", defaultValue: "Not reachable")
        }
        let relative = instance.lastSeenAt.formatted(.relative(presentation: .named))
        return String(
            format: L10n.string("mobile.deviceTree.lastSeenFormat", defaultValue: "Last seen %@"),
            relative
        )
    }
}

/// A leaf placeholder shown when an expanded instance has no visible workspaces:
/// either it is not the connected build (offer Connect) or it is connected but
/// has no workspaces yet.
struct DeviceTreeWorkspacePlaceholderRow: View {
    let isActiveInstance: Bool
    let hasRoutes: Bool
    let connect: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let connect, !isActiveInstance {
                Button {
                    connect()
                } label: {
                    Text(L10n.string("mobile.deviceTree.connectToView", defaultValue: "Connect to view"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 36, bottom: 4, trailing: 12))
        .accessibilityIdentifier("MobileDeviceTreeWorkspacePlaceholder")
    }

    private var message: String {
        if isActiveInstance {
            return L10n.string("mobile.deviceTree.noWorkspaces", defaultValue: "No workspaces yet")
        }
        if !hasRoutes {
            return L10n.string("mobile.deviceTree.noRoutes", defaultValue: "Not reachable")
        }
        return L10n.string(
            "mobile.deviceTree.connectToSeeWorkspaces",
            defaultValue: "Connect to this build to see its workspaces"
        )
    }
}
#endif
