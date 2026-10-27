import GhosttyNextKit

extension GhosttyRuntime {
    /// The resolved `clipboard-write` value. cmux keeps Ghostty's own
    /// semantics: `allow` (the default) writes silently, `ask` shows the
    /// consent dialog, `deny` drops the write.
    /// `config` is a live handle the caller holds for the call.
    nonisolated static func clipboardWriteValue(_ config: ghostty_config_t) -> String? {
        // SAFETY: the caller's live config; clipboard-write is a string (the enum's name).
        unsafe configString(config, key: "clipboard-write")
    }
}
