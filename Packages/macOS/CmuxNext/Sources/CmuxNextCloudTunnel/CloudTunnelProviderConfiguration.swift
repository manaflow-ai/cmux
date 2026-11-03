public import Foundation

/// The `providerConfiguration` dictionary the app saves and the extension reads. Versioned so an
/// extension can refuse a shape it does not know instead of misreading it.
public struct CloudTunnelProviderConfiguration: Sendable, Equatable {
    /// The shape this build writes and reads.
    public static let schemaVersion = 1

    /// The completed wg-quick config, private key included.
    public let wgQuick: String

    public init(wgQuick: String) {
        self.wgQuick = wgQuick
    }

    /// Reads a saved dictionary; `nil` for a missing config or another schema.
    public init?(dictionary: [String: Any]?) {
        guard let dictionary,
              dictionary["schemaVersion"] as? Int == Self.schemaVersion,
              let wgQuick = dictionary["wgQuickConfig"] as? String, !wgQuick.isEmpty else { return nil }
        self.wgQuick = wgQuick
    }

    /// The dictionary to save.
    public var dictionary: [String: Any] {
        ["wgQuickConfig": wgQuick, "schemaVersion": Self.schemaVersion]
    }
}
