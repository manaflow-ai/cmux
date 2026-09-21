import Foundation

/// What the account's presence service says about another Mac's app instance,
/// carried on ``SurfaceMachineInfo`` so the Devices tree, `surface.catalog`, and
/// `cmux vm tree --json` all render the same liveness. Nil on local and cloud
/// machines, which have no presence record.
struct SurfaceDevicePresence: Hashable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case online
        case offline
        /// No presence report: the stream is down, or the device is known only
        /// from its pairing. A paired Mac still dials; the link decides.
        case unknown
    }

    /// Whether this Mac's account may drive the device. The host authorizes only
    /// the account that is signed in on it, so the viewer never dials (and never
    /// presents its bearer token to) a Mac owned by another team member.
    enum AccountTrust: String, Codable, Sendable {
        /// The device is owned by the signed-in account.
        case sameAccount
        /// The device belongs to another member of the team.
        case otherAccount
        /// The directory has not learned the owner yet.
        case unknown
    }

    var state: State
    /// Freshest heartbeat the service reported, when it reported any.
    var lastSeenAt: Date?
    /// The app-instance tag (`default` for stable builds).
    var tag: String
    /// The host app's bundle id, for build-channel labels; nil for older hosts.
    var bundleID: String?
    var accountTrust: AccountTrust

    var isOnline: Bool { state == .online }

    /// "DEV · issue-8001" for tagged dev builds, "Nightly" / "RC" for those
    /// channels, nil for a stable instance (whose name needs no qualifier).
    var buildLabel: String? {
        let lowered = (bundleID ?? "").lowercased()
        let taggedName = tag != SurfaceDeviceInstanceID.defaultTag ? tag : nil
        let channel: String
        if lowered.hasPrefix("dev.cmux") || lowered.contains(".debug") {
            channel = String(localized: "cloudTree.device.build.dev", defaultValue: "DEV")
        } else if lowered.hasSuffix(".nightly") || lowered.contains(".nightly.") {
            channel = String(localized: "cloudTree.device.build.nightly", defaultValue: "Nightly")
        } else if lowered.hasSuffix(".rc") || lowered.contains(".rc.") {
            channel = String(localized: "cloudTree.device.build.rc", defaultValue: "RC")
        } else if lowered.hasSuffix(".staging") || lowered.contains(".staging.") {
            channel = String(localized: "cloudTree.device.build.staging", defaultValue: "Staging")
        } else {
            return taggedName
        }
        guard let taggedName else { return channel }
        return String(format: String(localized: "cloudTree.device.build.tagged", defaultValue: "%1$@ · %2$@"), channel, taggedName)
    }
}
