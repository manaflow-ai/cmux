import GhosttyNextKit

extension GhosttyRuntime {
    /// Per-screen Kitty graphics budget for a Mac viewer. Ghostty keeps a
    /// separate budget for the primary and alternate screens, so a surface
    /// may retain about twice this value. User config loads afterward and
    /// may explicitly choose another limit.
    static let cmuxDefaultImageStorageBytes: UInt32 = 5_000_000

    /// Loads the bounded viewer default before the user's Ghostty files.
    static func loadImageStorageDefault(into config: ghostty_config_t) {
        let line = "image-storage-limit = \(cmuxDefaultImageStorageBytes)"
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
    }
}
