enum BrowserAuthCallbackNavigationDisposition {
    /// The app's own trusted callback: consume it and deliver in-process.
    case deliverInApp
    /// Auth-callback-shaped URL that failed the trust checks: cancel the
    /// navigation without delivering or prompting.
    case block
    /// Not a user-activated auth callback; regular handling applies.
    case passThrough
}
