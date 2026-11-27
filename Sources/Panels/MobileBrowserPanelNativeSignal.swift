import CMUXMobileCore

enum MobileBrowserPanelNativeSignal {
    case dirty(editableFocused: Bool?)
    case stateChanged
    case webViewReplaced
    case dialog(MobileBrowserDialogEvent)
    case dialogResolved(MobileBrowserDialogResolvedEvent)
    case closed
}
