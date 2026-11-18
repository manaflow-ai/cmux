public import CmuxNextDesign

/// The question the first app shortcut pressed in a web page asks, before the page or cmux gets the key (CMUX-641:
/// Linear's Cmd-K opened cmux Search Chats, not Linear's palette): use the key in the page or in cmux. Two short
/// lines under it (Lucas 2026-11-18: the first version was too much text): the answer covers every shared shortcut and
/// can change in Settings, and focus mode's key gives a page every key. The answer is a `browser.pageShortcuts` value.
/// Neither Return nor Escape answers: the person picks a button.
public nonisolated struct BrowserPageShortcutsPrompt: Equatable, Sendable {
    /// `browser.pageShortcuts` values the buttons answer.
    public static let pageFirst = "page"
    public static let cmuxFirst = "cmux"
    /// The check box that makes the answer every site's (`browser.pageShortcuts`), not this site's alone.
    public static let allSites = "allSites"

    /// The key pressed (`⌘K`).
    public var key: String
    /// The page's site (`linear.app`).
    public var host: String
    /// The focus mode shortcut (`⌥⌘↩`), nil when unbound.
    public var focusMode: String?

    public init(key: String, host: String, focusMode: String?) {
        (self.key, self.host, self.focusMode) = (key, host, focusMode)
    }

    public var spec: CmuxDialogSpec {
        // Command first, as it is said ("Command-Option-Return"; Lucas 2026-11-18), not the menu's ⌥⌘ order.
        let tip = focusMode.map { Strings.PageShortcuts.tip(shortcut: Self.commandFirst($0)) } ?? Strings.PageShortcuts.tipUnbound
        let lines = [Strings.PageShortcuts.siteScope(host: host) + "\n"]  // an empty line above the check box (Lucas 2026-11-18)
        return CmuxDialogSpec(title: Strings.PageShortcuts.title(host: host, key: key), lines: lines,
                              // The tip under the check box (Lucas 2026-11-18).
                              fields: [.check(id: Self.allSites, title: Strings.PageShortcuts.allSites, on: false), .note(tip, danger: false)],
                              // No Return or Escape: the person reads it and clicks one (Lucas 2026-11-18); Tab and Space still work.
                              buttons: [CmuxDialogButton(id: Self.cmuxFirst, title: Strings.PageShortcuts.cmuxFirst, role: .normal),
                                        CmuxDialogButton(id: Self.pageFirst, title: Strings.PageShortcuts.pageFirst, role: .normal)],
                              identifier: "cmux.dialog.pageShortcuts")
    }

    /// Whether the answer is every site's (`browser.pageShortcuts`); else it is this site's (`browser.pageShortcutSites`).
    public func appliesToAllSites(_ answer: CmuxDialogAnswer) -> Bool { answer.isOn(Self.allSites) }

    /// `⌥⌘↩` as `⌘⌥↩`: the Command glyph first.
    static func commandFirst(_ keys: String) -> String {
        keys.contains("⌘") ? "⌘" + keys.replacingOccurrences(of: "⌘", with: "") : keys
    }

    /// The `browser.pageShortcuts` value a pressed button answers; nil for a dismissal or another id.
    public func mode(for answer: CmuxDialogAnswer) -> String? {
        guard !answer.isDismissal, answer.button == Self.pageFirst || answer.button == Self.cmuxFirst else { return nil }
        return answer.button
    }
}

extension Strings {
    /// The page shortcuts dialog's text (Resources/Localizable.xcstrings).
    nonisolated enum PageShortcuts {
        /// "Use ⌘K in linear.app or in cmux?"
        static func title(host: String, key: String) -> String {
            String(format: String(localized: "pageShortcuts.ask.titleHost", defaultValue: "Use %1$@ in %2$@ or in cmux?", bundle: .module), key, host)
        }

        /// `%@` is the site (linear.app).
        static func siteScope(host: String) -> String {
            String(format: String(localized: "pageShortcuts.ask.siteScope", defaultValue: "Applies to every shortcut %@ shares with cmux. Change it anytime in Settings > Browser.", bundle: .module), host)
        }

        static var allSites: String {
            String(localized: "pageShortcuts.ask.allPages", defaultValue: "Use my preference for all web pages", bundle: .module)
        }

        /// `%@` is the focus mode shortcut (⌥⌘↩).
        static func tip(shortcut: String) -> String {
            String(format: String(localized: "pageShortcuts.ask.tip", defaultValue: "Tip: press %@ to give a page every key.", bundle: .module), shortcut)
        }

        static var tipUnbound: String {
            String(localized: "pageShortcuts.ask.tipUnbound", defaultValue: "Tip: focus mode in the View menu gives a page every key.", bundle: .module)
        }

        static var pageFirst: String {
            String(localized: "pageShortcuts.button.usePage", defaultValue: "Use in Page", bundle: .module)
        }

        static var cmuxFirst: String {
            String(localized: "pageShortcuts.button.useCmux", defaultValue: "Use in cmux", bundle: .module)
        }
    }
}
