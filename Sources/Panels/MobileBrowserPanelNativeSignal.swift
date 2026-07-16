enum MobileBrowserPanelNativeSignal {
    case dirty(editableFocused: Bool?)
    case stateChanged
    case webViewReplaced
    case closed
}
