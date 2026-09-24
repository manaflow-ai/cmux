import Foundation

/// Another Mac's header row in the Cloud-style outline: the same slot a cloud
/// machine row occupies, with account presence instead of a fleet status.
struct CloudTreeDeviceRow: Equatable {
    let instance: SurfaceDeviceInstanceID
    /// The device's own name, without any instance-tag suffix; the row shows
    /// the tag separately (``tagLabel``) so a name is never qualified twice.
    let name: String
    let presence: SurfaceDevicePresence?
    let linkState: SurfaceLinkState
    let linkError: String?
    let workspaceCount: Int
    let terminalCount: Int

    var machine: SurfaceMachineID { .device(instance) }

    /// The instance tag a non-stable build shows after its name ("nightly",
    /// "issue-8001"); nil for the stable channel, whose name needs no qualifier.
    var tagLabel: String? { instance.isDefaultTag ? nil : instance.tag }

    /// What quick-search (`/`) and assistive technology match: the name plus
    /// the tag, so a dev build is found by either.
    var searchableTitle: String {
        guard let tagLabel else { return name }
        return "\(name) \(tagLabel)"
    }

    /// Online means presence says so or the link is live (a Mac that answers
    /// is online whatever presence knows).
    var isOnline: Bool { Self.isOnline(presence: presence, linkState: linkState) }

    static func isOnline(presence: SurfaceDevicePresence?, linkState: SurfaceLinkState) -> Bool {
        linkState == .connected || presence?.isOnline == true
    }

    /// Creation requires an authenticated live link; discovery alone only
    /// makes a device visible. Shared by hover controls, menus, and children.
    var canCreateWorkspacesAndTerminals: Bool {
        linkState == .connected && presence?.accountTrust == .sameAccount
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
                    return format.replacingOccurrences(of: "%@", with: Self.relativeAge(from: lastSeen, now: now))
                }
                return String(localized: "cloudTree.device.status.unknown", defaultValue: "Not seen yet")
            }
            if let lastSeen = presence?.lastSeenAt {
                let format = String(localized: "cloudTree.device.status.offlineSince", defaultValue: "Offline \u{00B7} seen %@")
                return format.replacingOccurrences(of: "%@", with: Self.relativeAge(from: lastSeen, now: now))
            }
            return String(localized: "cloudTree.device.status.offline", defaultValue: "Offline")
        }
        switch linkState {
        case .connected, .notApplicable:
            return String(localized: "cloudTree.device.status.online", defaultValue: "Online")
        case .connecting:
            if let linkError { return linkError }
            return String(localized: "cloudTree.device.status.connecting", defaultValue: "Connecting\u{2026}")
        case .error:
            return linkError ?? String(localized: "cloudTree.device.status.linkFailed", defaultValue: "Link failed")
        case .unavailable:
            return linkError ?? String(localized: "cloudTree.device.status.unavailable", defaultValue: "Unavailable")
        case .asleep, .offline:
            return String(localized: "cloudTree.device.status.offline", defaultValue: "Offline")
        }
    }

    /// The status worth a word on the row itself. A plainly online Mac shows
    /// none (an undimmed row already says so, the way This Mac's row does);
    /// everything else — offline, connecting, a failed link, another
    /// account — earns the dim fact after the name.
    func inlineStatus(now: Date = Date()) -> String? {
        if indicator == .online, presence?.accountTrust != .otherAccount { return nil }
        return statusLabel(now: now)
    }

    /// "2m ago" / "3h ago" / "5d ago" for the offline fact.
    static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return String(localized: "cloudTree.device.age.justNow", defaultValue: "just now")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(localized: "cloudTree.device.age.minutes", defaultValue: "\(minutes)m ago")
        }
        let hours = minutes / 60
        if hours < 48 {
            return String(localized: "cloudTree.device.age.hours", defaultValue: "\(hours)h ago")
        }
        return String(localized: "cloudTree.device.age.days", defaultValue: "\(hours / 24)d ago")
    }

    /// The tag-qualified display name for text-only contexts (`surface.catalog`,
    /// progress and error labels): "Studio (issue-8001)" for a dev build, the
    /// bare name for stable. Idempotent — a host already reports its instance
    /// name with this suffix (`MobileHostIdentity.instanceDisplayName`), and
    /// qualifying it again must not read "Studio (issue-8001) (issue-8001)".
    static func displayName(baseName: String, instance: SurfaceDeviceInstanceID) -> String {
        let base = self.baseName(from: baseName, instance: instance)
        guard !instance.isDefaultTag else { return base }
        return base + tagSuffix(for: instance)
    }

    /// The name without its instance-tag suffix, however many times a merge of
    /// host, pairing, and registry names has applied it; an empty name falls
    /// back to the device id's first eight characters.
    static func baseName(from name: String, instance: SurfaceDeviceInstanceID) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instance.isDefaultTag {
            let suffix = tagSuffix(for: instance)
            while trimmed.hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed.isEmpty ? String(instance.deviceID.prefix(8)) : trimmed
    }

    private static func tagSuffix(for instance: SurfaceDeviceInstanceID) -> String {
        " (\(instance.tag))"
    }
}
