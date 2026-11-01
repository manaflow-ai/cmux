import Foundation

/// Facts about the focused surface that the focus state does not hold: what `KeyRouter`
/// reads besides the focus state to build a key's context.
public nonisolated struct KeyFacts: Equatable, Sendable {
    /// The key window's first responder has marked text (an input method
    /// is composing).
    public var hasMarkedText = false
    /// The focused terminal is in copy mode.
    public var terminalCopyMode = false
    /// The focused terminal is using Ghostty's alternate screen.
    public var terminalAlternateScreen = false
    /// The focused screen has a primary input and none of its text
    /// fields has the keyboard (`PrimaryInputTarget`).
    public var primaryInputReady = false
    /// The focused screen's primary input claims this key wherever in the
    /// screen the keyboard is (`PrimaryInputTarget.routesToPrimaryInput`):
    /// printable and dead keys, plus any key the screen adds (Home's history
    /// arrows). Read only for a key that is not a Command or Control chord.
    public var primaryInputClaimsKey = false
    /// The focused page cannot take typing yet: its document has not
    /// focused its primary input, or keys typed before still wait.
    public var pageInputPending = false
    /// The key goes to the Chromium page window of a page the focus model does not name (a chat
    /// beside the focused Markdown page, #25666): AppKit sends it to that page, so the focused
    /// page's type-ahead queue and primary input never take it.
    public var keyInOtherPage = false
    /// The focused React page's id (`cmux.markdown`): context key
    /// `pageId`; the markdown page also sets `markdownFocused`.
    public var pageID: String?
    /// The focused markdown page shows a file it cannot save
    /// (`markdownReadOnlyFocused`, else `markdownEditorFocused`).
    public var markdownReadOnly = false
    /// A list-like control in the focused page has the keyboard (R85;
    /// the sidebar list and its field imply it without this).
    public var listFocus = false
    /// An editable element in the focused page has the keyboard (a text
    /// field, Monaco, a content-editable): bare keys are typing there.
    public var pageEditableFocused = false
    /// The focused address bar shows its suggestion list: it is a list
    /// for Ctrl-N/P/J/K (R110) until the list closes.
    public var omnibarListOpen = false
    /// The focused internal page's id when its tab id does not name it
    /// (a store page tab, `page-tabs-v1`).
    public var internalPage: String?
    /// The window shows a page with its own history (`PageHistory`):
    /// Cmd-[ / Cmd-] run Go Back / Go Forward there.
    public var showsPageHistory = false
    /// The top page the window shows (`home`), which fills the content
    /// area without a pane: its `surfaceKind`.
    public var topPage: String?
    /// The focused code editor waits for the second key of its own key sequence (Monaco's
    /// Cmd-K Cmd-0): the next key goes to it, not to an app binding (`cmux.editor.keySequence`).
    public var pageKeySequencePending = false
    /// A terminal's TextBox composer has the keyboard (`textBoxFocused`): its Shift-Tab cycles the
    /// submit action instead of reaching the terminal.
    public var textBoxFocused = false
    /// The window's sidebar has two or more rows selected (`sidebar.multiSelection` while it has the keyboard).
    public var sidebarMultiSelection = false
    /// The right sidebar's file explorer list has the keyboard (`fileExplorerFocused`).
    public var fileExplorerFocused = false
    /// Workspaces as tabs is on (`SidebarTunables.workspacesAsTabs`): context key `sidebar.workspacesAsTabs`.
    public var workspacesAsTabs = false
    /// The focused browser page reports the keys it did not handle (a Chromium tab, through
    /// `CefKeyboardHandler::OnKeyEvent`): Find and content shortcuts go to it first
    /// (``KeyRouter/offersToPage(_:event:focus:facts:)``).
    public var pageReportsUnhandledKeys = false

    public init(hasMarkedText: Bool = false, terminalCopyMode: Bool = false,
                terminalAlternateScreen: Bool = false, primaryInputReady: Bool = false,
                primaryInputClaimsKey: Bool = false, pageInputPending: Bool = false,
                keyInOtherPage: Bool = false, pageID: String? = nil,
                markdownReadOnly: Bool = false, listFocus: Bool = false,
                pageEditableFocused: Bool = false, omnibarListOpen: Bool = false,
                internalPage: String? = nil, showsPageHistory: Bool = false,
                topPage: String? = nil, pageKeySequencePending: Bool = false,
                textBoxFocused: Bool = false, sidebarMultiSelection: Bool = false,
                fileExplorerFocused: Bool = false, workspacesAsTabs: Bool = false,
                pageReportsUnhandledKeys: Bool = false) {
        self.hasMarkedText = hasMarkedText
        self.terminalCopyMode = terminalCopyMode
        self.terminalAlternateScreen = terminalAlternateScreen
        self.primaryInputReady = primaryInputReady
        self.primaryInputClaimsKey = primaryInputClaimsKey
        self.pageInputPending = pageInputPending
        self.keyInOtherPage = keyInOtherPage
        self.pageID = pageID
        self.markdownReadOnly = markdownReadOnly
        self.listFocus = listFocus
        self.pageEditableFocused = pageEditableFocused
        self.omnibarListOpen = omnibarListOpen
        self.internalPage = internalPage
        self.showsPageHistory = showsPageHistory
        self.topPage = topPage
        self.pageKeySequencePending = pageKeySequencePending
        self.textBoxFocused = textBoxFocused
        self.sidebarMultiSelection = sidebarMultiSelection
        self.fileExplorerFocused = fileExplorerFocused
        self.workspacesAsTabs = workspacesAsTabs
        self.pageReportsUnhandledKeys = pageReportsUnhandledKeys
    }
}
