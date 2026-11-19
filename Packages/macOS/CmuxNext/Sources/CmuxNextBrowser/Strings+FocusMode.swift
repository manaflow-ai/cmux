import Foundation

// cmux mode (browser focus mode's flag; CMUX-641): its omnibar badge, and the notice the first time a page keeps a
// cmux shortcut.
nonisolated extension Strings {
    static var cmuxModeActive: String {
        String(localized: "browser.cmuxMode.active", defaultValue: "cmux Mode", bundle: .module)
    }
    /// The badge's tooltip: a click leaves cmux mode.
    static var cmuxModeExitHelp: String {
        String(localized: "browser.cmuxMode.exit.help", defaultValue: "Leave cmux mode: web pages get their shortcuts first again", bundle: .module)
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

    public var message: String { Strings.cmuxModeNotice(key: key, toggle: toggle) }
}
