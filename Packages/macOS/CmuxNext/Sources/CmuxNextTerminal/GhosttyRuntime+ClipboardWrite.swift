import GhosttyNextKit

extension GhosttyRuntime {
    /// Program-originated writes always require consent in cmux. Preserve a
    /// user's stricter `deny`; Ghostty's `allow` becomes `ask` after all user
    /// files load so OSC 52/Kitty status replies track the actual decision.
    static func enforceClipboardWriteConsent(into config: ghostty_config_t) {
        guard clipboardWriteValue(config) == "allow" else { return }
        let line = "clipboard-write = ask"
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
    }

    nonisolated static func clipboardWriteValue(_ config: ghostty_config_t) -> String? {
        var name: UnsafePointer<CChar>?
        let key = "clipboard-write"
        let found = withUnsafeMutablePointer(to: &name) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        return found ? name.map { String(cString: $0) } : nil
    }
}
