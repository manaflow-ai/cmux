// Command execution policy shared by palette selection and focus restoration.
extension ContentView {
    static func commandPaletteShouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             "palette.layout.saveCurrent",
             "palette.swapWithSession",
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode",
             // Pane focus moves the first responder synchronously; dismissing
             // afterwards would clear it with makeFirstResponder(nil).
             "palette.focusPaneLeft",
             "palette.focusPaneRight",
             "palette.focusPaneUp",
             "palette.focusPaneDown",
             "palette.focusPreviousPane",
             "palette.focusNextPane",
             // Onboarding presents a separate window and must run
             // after the palette releases its responder and focus guard.
             Self.commandPaletteComputerUseOpenSetupCommandId,
             Self.commandPaletteComputerUseAccessibilityCommandId,
             Self.commandPaletteComputerUseScreenRecordingCommandId:
            return true
        default:
            return false
        }
    }
}
