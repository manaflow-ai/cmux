import Foundation

/// Collision-free identity of one finalized effective Ghostty configuration.
struct GhosttyConfigurationContentIdentity: Equatable {
    private let serializedConfiguration: Data

    init?(_ config: ghostty_config_t) {
        let exported = ghostty_config_serialize(config)
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr else { return nil }
        serializedConfiguration = Data(
            bytes: pointer,
            count: Int(exported.len)
        )
    }
}
