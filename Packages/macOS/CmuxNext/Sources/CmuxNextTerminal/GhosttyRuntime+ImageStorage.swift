import GhosttyNextKit

extension GhosttyRuntime {
    /// Per-screen Kitty graphics budget for a Mac viewer. Ghostty keeps a
    /// separate budget for the primary and alternate screens, so a surface
    /// may retain about twice this value. An explicit config or theme value
    /// takes precedence.
    nonisolated static let cmuxDefaultImageStorageBytes: UInt32 = 5_000_000

    /// Loads the bounded viewer default after finalization only when neither
    /// the user's config files nor their theme assigned the key.
    nonisolated static func loadImageStorageDefaultIfUnset(into config: ghostty_config_t) {
        let key = "image-storage-limit"
        var source = ghostty_config_source_s()
        // SAFETY: the caller passes a live config; Swift passes a NUL-terminated copy of `key`
        // for the call, and Ghostty fills `source`, which lives for the call.
        let explicitlySet = unsafe ghostty_config_key_source(config, key, UInt(key.utf8.count), &source)
        guard !explicitlySet else { return }
        let line = "image-storage-limit = \(cmuxDefaultImageStorageBytes)"
        // SAFETY: the caller passes a live config.
        unsafe loadConfigLine(line, into: config, source: "cmux-next")
    }
}
