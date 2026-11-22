import Foundation
import GhosttyNextKit

/// Ghostty's `macos-option-as-alt` (`false`, `true`, `left`, `right`) as the C API returns it: the enum's name. A
/// terminal view's key encoder applies it itself; a key typed for a terminal with no view (the daemon types it) reads
/// it here, so the same bytes reach the terminal (P0 1193).
extension GhosttyRuntime {
    /// `macos-option-as-alt` of the applied config; nil when no config loaded or the key is unreadable.
    public var optionAsAltValue: String? {
        guard let config else { return nil }
        return Self.optionAsAltValue(config)
    }

    /// `macos-option-as-alt` of a config made of `text` (Ghostty config lines), for tests.
    public nonisolated static func optionAsAltValue(configText text: String) -> String? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return optionAsAltValue(config)
    }

    nonisolated static func optionAsAltValue(_ config: ghostty_config_t) -> String? {
        var name: UnsafePointer<CChar>?
        let key = "macos-option-as-alt"
        let found = withUnsafeMutablePointer(to: &name) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        return found ? name.map { String(cString: $0) } : nil
    }
}
