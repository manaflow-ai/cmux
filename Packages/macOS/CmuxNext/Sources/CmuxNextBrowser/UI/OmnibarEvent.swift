public import Foundation

/// Where an omnibar commit opens (Enter with modifiers, a modified row click).
public typealias OmnibarDisposition = OmnibarInput.Disposition

/// Why the omnibar stopped editing.
public nonisolated enum OmnibarEndReason: Equatable, Sendable {
    /// Enter, a suggestion click, or Paste and Go: this tab loads `url`.
    case commit(URL)
    /// Cmd-Enter, Option-Enter, Shift-Enter or a modified row click: `url`
    /// opens in another tab or window; this tab keeps its page.
    case open(URL, OmnibarDisposition)
    /// Escape with nothing left to revert.
    case cancel
    /// Focus moved elsewhere (click, Tab, another pane).
    case blur
    /// Enter in an extension keyword session: the extension gets `text`
    /// (`chrome.omnibox.onInputEntered`) and decides what loads.
    case keyword(extensionID: String, text: String, disposition: OmnibarDisposition)
    /// Enter or a click on a Switch to Tab row: the App reveals tab `key`.
    case switchToTab(key: String)
}

/// Editing boundaries the App routes (focus handoff between the omnibar and
/// the page belongs to the App's focus owner, not to this view).
public nonisolated enum OmnibarEvent: Equatable, Sendable {
    case didBeginEditing
    case didEndEditing(OmnibarEndReason)
}
