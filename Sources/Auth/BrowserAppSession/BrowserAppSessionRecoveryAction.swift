/// The safe fallback after authenticated browser navigation cannot continue.
enum BrowserAppSessionRecoveryAction: Equatable {
    case beginSignIn
    case isolatedBrowser
}
