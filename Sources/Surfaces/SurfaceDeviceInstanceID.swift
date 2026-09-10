import CMUXMobileCore
import Foundation

/// The catalog identity of one tagged cmux app instance on another Mac signed
/// into this account: the physical device's registry UUID plus the app-instance
/// tag (`"default"` for stable, a launch tag for dev builds). The same pair keys
/// the device registry (`device_app_instances`) and the presence service, so a
/// row in the Devices sidebar, a registry instance, and a presence instance all
/// name one thing.
///
/// Wire form: `device:<uuid>@<tag>`. The prefix keeps the value distinct from
/// `"local"` and from every cloud machine id (slugs and provider ids never carry a
/// `device:` prefix), so ``SurfaceMachineID/init(rawValue:)`` stays backward
/// compatible with persisted sessions, `cloudTree.collapsedMachineIDs`, and the
/// `surface.catalog` JSON older CLIs already read. The UUID contains no `@`, so the
/// first `@` after the prefix splits identity from tag even for tags that contain one.
struct SurfaceDeviceInstanceID: Hashable, Codable, Sendable, CustomStringConvertible {
    static let wirePrefix = "device:"
    static let tagSeparator: Character = "@"
    /// The registry tag of the stable channel; every other tag is a build channel or dev launch tag.
    static let defaultTag = "default"

    /// Canonical lowercase device UUID (``cmxCanonicalDeviceID``).
    let deviceID: String
    /// Normalized app-instance tag; empty input becomes ``defaultTag``.
    let tag: String

    init(deviceID: String, tag: String) {
        self.deviceID = cmxCanonicalDeviceID(deviceID.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tag = trimmedTag.isEmpty ? Self.defaultTag : trimmedTag
    }

    /// Parses the wire form; nil for anything that is not a `device:` value.
    init?(wireValue: String) {
        guard wireValue.hasPrefix(Self.wirePrefix) else { return nil }
        let body = wireValue.dropFirst(Self.wirePrefix.count)
        guard let separator = body.firstIndex(of: Self.tagSeparator) else { return nil }
        let deviceID = String(body[..<separator])
        let tag = String(body[body.index(after: separator)...])
        guard !deviceID.isEmpty, !tag.isEmpty else { return nil }
        self.init(deviceID: deviceID, tag: tag)
    }

    var wireValue: String { "\(Self.wirePrefix)\(deviceID)\(Self.tagSeparator)\(tag)" }
    var description: String { wireValue }

    /// Whether this instance is the stable-channel app on its device.
    var isDefaultTag: Bool { tag == Self.defaultTag }

    /// Other physical Macs are visible in the viewer's channel. Dev viewers
    /// additionally see stable and nightly, but never unrelated dev tags.
    func isVisible(from viewer: SurfaceDeviceInstanceID) -> Bool {
        guard deviceID != viewer.deviceID else { return false }
        if tag == viewer.tag { return true }
        switch viewer.tag {
        case Self.defaultTag, "nightly", "rc", "staging":
            return false
        default:
            return isDefaultTag || tag == "nightly"
        }
    }

    /// The shared cross-app spelling used by pairing and presence code.
    var appInstanceIdentity: CmxMacAppInstanceIdentity {
        CmxMacAppInstanceIdentity(macDeviceID: deviceID, instanceTag: isDefaultTag ? nil : tag)
    }
}
