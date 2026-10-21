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
            ? "It's online, so it will disconnect now. It stays off until you choose Allow Again in Settings → Mobile on that Mac."
            : "It's online, so cmux on that Mac can add it back. To keep it off, turn off Settings → Mobile on that Mac."
    }
}
