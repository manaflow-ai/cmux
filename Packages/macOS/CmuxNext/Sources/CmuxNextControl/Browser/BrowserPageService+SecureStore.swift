import CmuxNextDaemon

/// The app's `browser.page.fill_login` lookup, apart from the files that use the control
/// module's JSON value (CmuxNextDaemon has its own type of that name).
extension BrowserPageService {
    /// ``ChiefSecureStore``, the login keychain, read off every actor since its calls block. The
    /// store matches the site or a parent domain of `host` (`www.linkedin.com` uses `linkedin.com`).
    public static let secureStoreLogins: BrowserPageLogins = { host in
        await Task.detached(priority: .userInitiated) {
            ChiefSecureStore().credential(forHost: host).map { BrowserPageLogin(site: $0.site, username: $0.username, password: $0.password) }
        }.value
    }
}
