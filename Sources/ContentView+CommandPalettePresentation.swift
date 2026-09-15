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
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode",
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
