import Foundation

// cmux mode (browser focus mode's flag; CMUX-641): its omnibar badge, and the notice the first time a page keeps a
// cmux shortcut.
nonisolated extension Strings {
    static var cmuxModeActive: String {
        String(localized: "browser.cmuxMode.active", defaultValue: "cmux mode", bundle: .module)
    }
    /// The badge's tooltip, as macOS says it for full screen ("Press Esc to exit full screen"): `keys` is the toggle (⌘⌥↩).
    static func cmuxModeExitHelp(keys: String) -> String {
        String(format: String(localized: "browser.cmuxMode.exit.helpWithKeys", defaultValue: "Press %@ to exit cmux mode", bundle: .module), keys)
    }
    /// The badge's tooltip when the toggle has no key.
    static var cmuxModeExitHelp: String {
        String(localized: "browser.cmuxMode.exit.help", defaultValue: "Click to exit cmux mode", bundle: .module)
    }
    /// The one-time notice: `key` (⌘K) went to the page; `toggle` (⌘⌥↩) turns on cmux mode.
    static func cmuxModeNotice(key: String, toggle: String) -> String {
        String(format: String(localized: "browser.cmuxMode.notice", defaultValue: "%1$@ went to the web page. Press %2$@ for cmux mode, where cmux gets every shortcut.", bundle: .module), key, toggle)
    }
}

/// The one-time cmux mode notice's text, for the key router: `key` (⌘K) went to the page, `toggle` (⌘⌥↩) turns on
/// cmux mode.
public nonisolated struct BrowserCmuxModeNotice: Equatable, Sendable {
    public var key: String
    public var toggle: String

    public init(key: String, toggle: String) {
        (self.key, self.toggle) = (key, toggle)
    }

    public var message: String { Strings.cmuxModeNotice(key: key, toggle: Self.commandFirst(toggle)) }

    /// `keys` with Command first (⌥⌘↩ reads ⌘⌥↩), as cmux mode's copy prints its keys (Lucas 2026-11-19: "Cmd Opt
    /// Enter"). A menu still draws macOS's own order.
    public static func commandFirst(_ keys: String) -> String {
        guard let command = keys.firstIndex(of: "⌘"), command != keys.startIndex else { return keys }
        var rest = keys
        rest.remove(at: command)
        return "⌘" + rest
    }
}
