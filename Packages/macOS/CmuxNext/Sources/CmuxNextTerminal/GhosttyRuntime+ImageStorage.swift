import GhosttyNextKit

extension GhosttyRuntime {
    /// Per-screen Kitty graphics budget for a Mac viewer. Ghostty keeps a
    /// separate budget for the primary and alternate screens, so a surface
    /// may retain about twice this value. An explicit config or theme value
    /// takes precedence.
    static let cmuxDefaultImageStorageBytes: UInt32 = 5_000_000

    /// Loads the bounded viewer default after finalization only when neither
    /// the user's config files nor their theme assigned the key.
    static func loadImageStorageDefaultIfUnset(into config: ghostty_config_t) {
        let key = "image-storage-limit"
        var source = ghostty_config_source_s()
        let explicitlySet = key.withCString {
            ghostty_config_key_source(config, $0, UInt(key.utf8.count), &source)
        }
        guard !explicitlySet else { return }
        let line = "image-storage-limit = \(cmuxDefaultImageStorageBytes)"
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
    }
}
