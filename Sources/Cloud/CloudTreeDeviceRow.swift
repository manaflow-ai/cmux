import Foundation

/// Another Mac's header row in the Cloud-style outline: the same slot a cloud
/// machine row occupies, with account presence instead of a fleet status.
struct CloudTreeDeviceRow: Equatable {
    let instance: SurfaceDeviceInstanceID
    /// The device's display name, tag-qualified for non-default app instances
    /// ("Studio (issue-8001)"), so two dev builds on one Mac stay distinguishable.
    let name: String
    let presence: SurfaceDevicePresence?
    let linkState: SurfaceLinkState
    let linkError: String?
    let workspaceCount: Int
    let terminalCount: Int

    var machine: SurfaceMachineID { .device(instance) }

    /// Online means presence says so or the link is live (a Mac that answers
    /// is online whatever presence knows).
    var isOnline: Bool { linkState == .connected || presence?.isOnline == true }

    /// Creation requires an authenticated live link; discovery alone only
    /// makes a device visible. Shared by hover controls, menus, and children.
    var canCreateWorkspacesAndTerminals: Bool {
        linkState == .connected && presence?.accountTrust != .otherAccount
    }

    private var presenceUnknown: Bool { presence?.state == .unknown }

    /// The presence glyph's meaning, folded from presence and link state.
    enum Indicator: Equatable {
        case online
        case connecting
        case offline
        case attention
    }

    var indicator: Indicator {
        guard isOnline else { return linkState == .connecting ? .connecting : .offline }
        switch linkState {
        case .connected, .notApplicable: return .online
        case .connecting: return .connecting
        case .error, .unavailable: return .attention
        case .asleep, .offline: return .offline
        }
    }

    /// The dim inline fact after the name: liveness, or why the link is not usable.
    func statusLabel(now: Date = Date()) -> String {
        if presence?.accountTrust == .otherAccount {
            return String(localized: "cloudTree.device.status.otherAccount", defaultValue: "Another account")
        }
        guard isOnline else {
            if linkState == .connecting {
                return String(localized: "cloudTree.device.status.connecting", defaultValue: "Connecting\u{2026}")
            }
            if presenceUnknown {
                if let lastSeen = presence?.lastSeenAt {
                    let format = String(localized: "cloudTree.device.status.unknownSince", defaultValue: "Last seen %@")
                    return String(format: format, Self.relativeAge(from: lastSeen, now: now))
                }
                return String(localized: "cloudTree.device.status.unknown", defaultValue: "Not seen yet")
            }
            if let lastSeen = presence?.lastSeenAt {
                let format = String(localized: "cloudTree.device.status.offlineSince", defaultValue: "Offline \u{00B7} seen %@")
                return String(format: format, Self.relativeAge(from: lastSeen, now: now))
            }
            return String(localized: "cloudTree.device.status.offline", defaultValue: "Offline")
        }
        switch linkState {
        case .connected, .notApplicable:
            return String(localized: "cloudTree.device.status.online", defaultValue: "Online")
        case .connecting:
            return String(localized: "cloudTree.device.status.connecting", defaultValue: "Connecting\u{2026}")
        case .error:
            return linkError ?? String(localized: "cloudTree.device.status.linkFailed", defaultValue: "Link failed")
        case .unavailable:
            return linkError ?? String(localized: "cloudTree.device.status.unavailable", defaultValue: "Unavailable")
        case .asleep, .offline:
            return String(localized: "cloudTree.device.status.offline", defaultValue: "Offline")
        }
    }

    /// "2m ago" / "3h ago" / "5d ago" for the offline fact.
    static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return String(localized: "cloudTree.device.age.justNow", defaultValue: "just now")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: String(localized: "cloudTree.device.age.minutes", defaultValue: "%dm ago"), minutes)
        }
        let hours = minutes / 60
        if hours < 48 {
            return String(format: String(localized: "cloudTree.device.age.hours", defaultValue: "%dh ago"), hours)
        }
        return String(format: String(localized: "cloudTree.device.age.days", defaultValue: "%dd ago"), hours / 24)
    }

    /// The tag-qualified display name the row and every progress label use.
    static func displayName(baseName: String, instance: SurfaceDeviceInstanceID) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(instance.deviceID.prefix(8)) : trimmed
        guard !instance.isDefaultTag else { return base }
        let suffix = " (\(instance.tag))"
        return base.hasSuffix(suffix) ? base : base + suffix
    }
}
