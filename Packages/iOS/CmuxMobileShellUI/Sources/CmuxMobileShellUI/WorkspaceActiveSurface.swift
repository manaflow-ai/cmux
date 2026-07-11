import Foundation

enum WorkspaceActiveSurface: Equatable {
    case terminal
    case chat
    case browser

    static func derive(isChatMode: Bool, hasChosenChatSession: Bool, hasActiveBrowser: Bool) -> Self {
        if isChatMode, hasChosenChatSession {
            return .chat
        }
        if hasActiveBrowser {
            return .browser
        }
        return .terminal
    }

    /// The terminal to refocus when chrome (chat/browser) returns to the
    /// terminal surface, or nil when autofocus must stay suppressed.
    ///
    /// The terminal stays mounted under chrome (an opacity swap, not a
    /// remount), so the attach-time autofocus in `didMoveToWindow` never
    /// re-fires on return. This guard drives the explicit focus-on-return
    /// path with the same conditions as attach autofocus (`shouldAutoFocus`
    /// in `WorkspaceDetailView.detailContent()`): a chrome-suppressed
    /// terminal or an open composer must not have the keyboard grabbed for
    /// it.
    static func chromeReturnRefocusTerminalID(
        selectedTerminalID: String?,
        shouldAutoFocusTerminal: (String) -> Bool,
        isComposerPresented: Bool
    ) -> String? {
        guard let selectedTerminalID,
              shouldAutoFocusTerminal(selectedTerminalID),
              !isComposerPresented else { return nil }
        return selectedTerminalID
    }
}
