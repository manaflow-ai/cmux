/// A recoverable toolbar-action failure shown by browser chrome.
public enum BrowserWebExtensionActionFailure: Equatable, Sendable {
    /// WebKit declared a popup action but never supplied a ready popup.
    case popupTimedOut

    /// The extension or associated tab disappeared before the action ran.
    case actionUnavailable

    /// The requested toolbar pin state could not be committed durably.
    case toolbarPinFailed
}
