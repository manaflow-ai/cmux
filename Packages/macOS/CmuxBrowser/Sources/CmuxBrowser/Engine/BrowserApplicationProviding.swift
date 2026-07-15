/// Supplies LaunchServices browser-handler and installed-application information.
@MainActor
public protocol BrowserApplicationProviding: AnyObject {
    /// Returns the applications LaunchServices selects for representative HTTPS and HTTP URLs.
    func defaultBrowserApplications() -> [BrowserApplication]

    /// Returns installed Chromium-family applications that cmux knows how to launch.
    func installedChromiumApplications() -> [BrowserApplication]
}
