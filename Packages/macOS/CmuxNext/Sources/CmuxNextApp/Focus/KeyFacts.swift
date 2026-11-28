import Foundation

/// Facts about the focused surface that the focus state does not hold: what `KeyRouter`
/// reads besides the focus state to build a key's context.
nonisolated struct KeyFacts: Equatable, Sendable {
    /// The key window's first responder has marked text (an input method
    /// is composing).
    var hasMarkedText = false
    /// The focused terminal is in copy mode.
    var terminalCopyMode = false
    /// The focused screen has a primary input and none of its text
    /// fields has the keyboard (`PrimaryInputTarget`).
    var primaryInputReady = false
    /// The focused page cannot take typing yet: its document has not
    /// focused its primary input, or keys typed before still wait.
    var pageInputPending = false
    /// The focused React page's id (`cmux.markdown`): context key
    /// `pageId`; the markdown page also sets `markdownFocused`.
    var pageID: String?
    /// A list-like control in the focused page has the keyboard (R85;
    /// the sidebar list and its field imply it without this).
    var listFocus = false
    /// An editable element in the focused page has the keyboard (a text
    /// field, Monaco, a content-editable): bare keys are typing there.
    var pageEditableFocused = false
    /// The focused address bar shows its suggestion list: it is a list
    /// for Ctrl-N/P/J/K (R110) until the list closes.
    var omnibarListOpen = false
    /// The focused internal page's id when its tab id does not name it
    /// (a store page tab, `page-tabs-v1`).
    var internalPage: String?
    /// The window shows a page with its own history (`PageHistory`):
    /// Cmd-[ / Cmd-] run Go Back / Go Forward there.
    var showsPageHistory = false
    /// The top page the window shows (`home`), which fills the content
    /// area without a pane: its `surfaceKind`.
    var topPage: String?
}
