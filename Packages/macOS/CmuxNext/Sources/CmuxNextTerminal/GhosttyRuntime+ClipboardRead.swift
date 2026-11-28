public import Foundation
import GhosttyNextKit

/// Ghostty's `clipboard-read` key (`allow`, `deny`, `ask`) as the C API
/// returns it: the enum's name. The App maps it onto the daemon module's
/// `ClipboardReadSetting` for the clipboard-read broker (this module does
/// not import CmuxNextDaemon).
extension GhosttyRuntime {
    /// `clipboard-read` of the applied config; nil when no config loaded
    /// (the broker then uses Ghostty's default, `ask`).
    public var clipboardReadValue: String? {
        guard let config else { return nil }
        return Self.clipboardReadValue(config)
    }

    /// `clipboard-read` of a config made of `text` (Ghostty config lines),
    /// for tests. Readable off the main actor.
    public nonisolated static func clipboardReadValue(configText text: String) -> String? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return clipboardReadValue(config)
    }

    /// The value in `config`; nil when the key is unreadable.
    nonisolated static func clipboardReadValue(_ config: ghostty_config_t) -> String? {
        var name: UnsafePointer<CChar>?
        let key = "clipboard-read"
        let found = withUnsafeMutablePointer(to: &name) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        return found ? name.map { String(cString: $0) } : nil
    }
}
