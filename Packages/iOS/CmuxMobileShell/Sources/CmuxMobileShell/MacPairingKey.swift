import CMUXMobileCore
public import CmuxMobilePairedMac
import Foundation

/// The typed owner key for everything the phone tracks per Mac APP INSTANCE:
/// connections, workspace state, notification-feed bookkeeping, routing, and
/// availability. One physical Mac running two builds (Stable + Nightly) is two
/// keys; a legacy untagged pairing collapses to its canonical device id, so
/// single-build Macs behave byte-for-byte as before the per-pairing re-key.
///
/// The typed key exists because the previous stringly-typed convention let
/// bare device ids and composite pairing ids share one `String` key space,
/// which produced a long tail of cross-build routing bugs. With this type the
/// compiler rejects a device id where a pairing key is required.
public struct MacPairingKey: Hashable, Sendable {
    /// The canonical physical-device id (UUID spellings lowercased).
    public let canonicalMacDeviceID: String
    /// The pairing's app-instance tag, whitespace-normalized; `nil` for a
    /// legacy untagged pairing (and for the anonymous-foreground sentinel).
    public let normalizedInstanceTag: String?

    /// Creates a key from raw identity fields.
    public init(macDeviceID: String, instanceTag: String?) {
        let identity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        self.canonicalMacDeviceID = identity.macDeviceID
        self.normalizedInstanceTag = identity.instanceTag
    }

    /// Parses either spelling of the string contract: a bare device id, or the
    /// composite `device`+U+001F+`tag` pairing id.
    public init(pairingID: String) {
        let identity = MobilePairedMac.pairingIdentity(from: pairingID)
        self.init(macDeviceID: identity.macDeviceID, instanceTag: identity.instanceTag)
    }

    /// The key for a stored pairing row. Pool identity is the STORED tag (the
    /// row's authority), never the authenticated tag adopted mid-session.
    public init(_ mac: MobilePairedMac) {
        self.init(macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag)
    }

    /// The pre-identity foreground slot: a manual/anonymous ticket connection
    /// whose Mac has not reported an identity yet. The literal is the
    /// long-standing `MobileShellComposite.foregroundAnonymousKey` sentinel
    /// (that property stays MainActor-isolated, so it cannot seed a
    /// nonisolated static here).
    public static let anonymousForeground = MacPairingKey(
        macDeviceID: "__cmux_foreground__",
        instanceTag: nil
    )

    /// The composite string spelling (`device`+U+001F+`tag`, or the bare
    /// device id when untagged) — the wire/persistence contract shared with
    /// `MobilePairedMac.pairingID`.
    public var pairingID: String {
        CmxMacAppInstanceIdentity(
            macDeviceID: canonicalMacDeviceID,
            instanceTag: normalizedInstanceTag
        ).id
    }

    /// Whether this key names an app instance on the given physical device.
    public func isOnDevice(_ macDeviceID: String) -> Bool {
        canonicalMacDeviceID == cmxCanonicalDeviceID(macDeviceID)
    }
}
