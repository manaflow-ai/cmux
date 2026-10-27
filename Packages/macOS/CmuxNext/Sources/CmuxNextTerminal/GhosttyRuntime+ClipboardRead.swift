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
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config).
        return unsafe Self.clipboardReadValue(config)
    }

    /// `clipboard-read` of a config made of `text` (Ghostty config lines),
    /// for tests. Readable off the main actor.
    public nonisolated static func clipboardReadValue(configText text: String) -> String? {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        let value = unsafe withScratchConfig(load: { unsafe loadConfigLine(text, into: $0, source: "test") },
                                             read: { unsafe clipboardReadValue($0) })
        return value ?? nil
    }

    /// The value in `config`, a live handle; nil when the key is unreadable.
    nonisolated static func clipboardReadValue(_ config: ghostty_config_t) -> String? {
        // SAFETY: the caller's live config; clipboard-read is a string (the enum's name).
        unsafe configString(config, key: "clipboard-read")
    }
}
