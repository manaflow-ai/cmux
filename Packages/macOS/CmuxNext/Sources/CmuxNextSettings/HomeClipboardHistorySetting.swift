/// `home.clipboardHistory` in cmux.json: the Chief composer's + menu lists your recent copies
/// (text and pictures) to attach with a click. On by default. The history stays in memory on this
/// Mac (never on disk, never sent); it is read from the pasteboard only when cmux becomes active
/// and when the + menu opens, and skips what password managers mark concealed or transient. Off,
/// cmux reads nothing for it and the Clipboard section is gone.
public nonisolated struct HomeClipboardHistorySetting {
    public nonisolated init() {}
    public static let configPath = ["home", "clipboardHistory"]
    public static let key = "home.clipboardHistory"
    public static let defaultEnabled = true
}
