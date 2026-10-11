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

/// The sign-in tabs and their callbacks. The shim learns a tab's callback
/// now, or when its browser attaches; its AUTH_CALLBACK events come back
/// here (`CEFRuntime.handle`) and go to the tab's handler.
@MainActor
public final class CEFSignInCallbacks {
    public static let shared = CEFSignInCallbacks()

    private struct Entry {
        weak var tab: CEFTab?
        let callback: CEFSignInCallback
        let handler: (URL) -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Makes `tab` a sign-in tab (nil clears it): `onCallback` gets the
    /// callback URL the shim stopped. Set before the first load.
    public func set(_ callback: CEFSignInCallback?, on tab: CEFTab, onCallback: ((URL) -> Void)?) {
        let key = ObjectIdentifier(tab)
        if let callback, let onCallback {
            entries[key] = Entry(tab: tab, callback: callback, handler: onCallback)
        } else {
            entries[key] = nil
        }
        apply(tab)
    }

    func attached(_ tab: CEFTab) {
        if entries[ObjectIdentifier(tab)] != nil { apply(tab) }
    }

    func stopped(browser: Int32, url: String) {
        entries = entries.filter { $0.value.tab != nil }
        guard let entry = entries.values.first(where: { $0.tab?.browserID == browser }), let url = URL(string: url) else { return }
        entry.handler(url)
    }

    private func apply(_ tab: CEFTab) {
        guard let browser = tab.browserID, let shim = tab.runtime.shim else { return }
        let callback = entries[ObjectIdentifier(tab)]?.callback ?? CEFSignInCallback()
        shim.setAuthCallback(browser, callback.scheme, callback.host, callback.path)
    }
}
