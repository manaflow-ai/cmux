import GhosttyNextKit

extension GhosttyRuntime {
    /// The resolved `clipboard-write` value. cmux keeps Ghostty's own
    /// semantics: `allow` (the default) writes silently, `ask` shows the
    /// consent dialog, `deny` drops the write.
    nonisolated static func clipboardWriteValue(_ config: ghostty_config_t) -> String? {
        var name: UnsafePointer<CChar>?
        let key = "clipboard-write"
        let found = withUnsafeMutablePointer(to: &name) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        return found ? name.map { String(cString: $0) } : nil
    }
}
