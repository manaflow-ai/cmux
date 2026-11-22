import Foundation

/// What the remove-Mac confirmation says about an online Mac. Only a Mac whose
/// host said `removal-v1` (its `version` service `capabilities`, PROTOCOL.md)
/// stays off once removed; an older Mac, or one this phone never linked to,
/// adds itself back, so the copy says that instead.
public struct MacRemovalCopy: Sendable {
    /// The `version` capability of a host that stays off after a removal.
    public static let capability = "removal-v1"

    /// Whether any of a Mac's device ids reported `removal-v1`; nil entries are unknown.
    public static func honorsRemoval(_ capabilities: [Set<String>?]) -> Bool {
        capabilities.contains { $0?.contains(capability) == true }
    }

    /// The sentence for an online Mac.
    public static func online(honorsRemoval: Bool) -> String {
        honorsRemoval
            ? String(localized: "mobile.devices.removal.supported", defaultValue: "Disconnects now. Reconnect with Allow Again in the Mac’s Settings → Mobile.", bundle: .module)
            : String(localized: "mobile.devices.removal.legacy", defaultValue: "May return automatically; turn off the Mac’s Settings → Mobile to prevent this.", bundle: .module)
    }
}
