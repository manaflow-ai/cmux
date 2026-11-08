internal import Foundation
public import GhosttyKit

/// Exact serialized identity of one finalized effective Ghostty configuration.
public struct GhosttyConfigurationContentIdentity: Equatable, Sendable {
    private let serializedConfiguration: Data

    /// Serializes a finalized Ghostty configuration into a stable value identity.
    ///
    /// - Parameter configuration: The finalized effective configuration to
    ///   identify.
    /// - Returns: `nil` when Ghostty cannot serialize the configuration.
    public init?(_ configuration: ghostty_config_t) {
        let exported = ghostty_config_serialize(configuration)
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr else { return nil }
        serializedConfiguration = Data(
            bytes: pointer,
            count: Int(exported.len)
        )
    }
}
