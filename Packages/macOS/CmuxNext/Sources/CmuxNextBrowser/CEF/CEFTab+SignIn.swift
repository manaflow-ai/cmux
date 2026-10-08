public import Foundation

/// The callback that ends a sign-in session (ASWebAuthenticationSession,
/// cmux as the default browser) running in a tab: a custom scheme, or an
/// https host and path. The shim cancels a main-frame navigation to it
/// before it loads (`cmux_shim_set_auth_callback`, auth_callback_policy.h),
/// so the callback URL never reaches the network or another app.
public nonisolated struct CEFSignInCallback: Equatable, Sendable {
    public var scheme: String
    public var host: String
    public var path: String

    public init(scheme: String = "", host: String = "", path: String = "") {
        self.scheme = scheme
        self.host = host
        self.path = path
    }
}

extension CEFTab {
    /// Makes this tab a sign-in tab: `onCallback` gets the callback URL the
    /// shim stopped. Set before the first load; it applies again on attach.
    public func setSignInCallback(_ callback: CEFSignInCallback?, onCallback: ((URL) -> Void)?) {
        signInCallback = callback
        signInHandler = onCallback
        applySignInCallback()
    }

    func applySignInCallback() {
        guard let browserID, let shim = runtime.shim else { return }
        let callback = signInCallback ?? CEFSignInCallback()
        shim.setAuthCallback(browserID, callback.scheme, callback.host, callback.path)
    }
}
