import CMUXMobileCore

enum MobileBrowserPanelNativeSignal {
    case dirty(editableFocused: Bool?)
    case stateChanged
    case webViewReplaced
    /// A viewport reflow was applied. The session schedules settle re-captures
    /// so a blank frame captured before the relayout paints cannot stick on an
    /// idle page that sends no further dirty signal.
    case reflowed
    case dialog(MobileBrowserDialogEvent)
    case dialogResolved(MobileBrowserDialogResolvedEvent)
    case closed
}
