import Foundation

/// The shared in-memory identity for one Mac app instance.
///
/// A physical device can run Stable, Nightly, and development builds at once.
/// The device identifier and normalized build tag therefore form one atomic
/// identity for routing, settings, persistence, and presentation.
public struct CmxMacAppInstanceIdentity: Hashable, Sendable {
    private static let separator: Character = "\u{1F}"

    /// The canonical physical-device identifier.
    public let macDeviceID: String
    /// The normalized app-build tag, or `nil` for an untagged legacy process.
    public let instanceTag: String?

    /// Creates an identity from its two app-instance fields.
    public init(macDeviceID: String, instanceTag: String?) {
        self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let normalizedTag = instanceTag?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.instanceTag = normalizedTag?.isEmpty == false ? normalizedTag : nil
    }

    /// Parses a composite identity or a legacy bare device identifier.
    public init(id: String) {
        let parts = id.split(
            separator: Self.separator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2, !parts[1].isEmpty else {
            self.init(macDeviceID: id, instanceTag: nil)
            return
        }
        self.init(macDeviceID: String(parts[0]), instanceTag: String(parts[1]))
    }

    /// The shared string spelling, device + U+001F + build tag.
    public var id: String {
        guard let instanceTag else { return macDeviceID }
        return "\(macDeviceID)\(Self.separator)\(instanceTag)"
    }
}
