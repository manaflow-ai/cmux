import CmuxNextActions

// Page chords a browser's own chrome runs (R88): KeyRouter.allows lets these
// content-tier actions take the key from the address bar and the find bar.
extension KeyRouter {
    /// Page actions Chrome and Safari run from the omnibox and the find bar.
    /// None of their chords is a text-editing chord, so the field loses
    /// nothing.
    nonisolated static let browserChromeActions: Set<ActionID> = [
        "browserBack", "browserForward", "browserReload", "browserHardReload", "browserShowHistory", "browser.copyURL",
        "browser.findPrevious",
    ]

    /// The address bar or the find bar of a browser tab has the keyboard.
    nonisolated static func isBrowserChromeField(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .addressBar, .findBar: true
        default: false
        }
    }
}
