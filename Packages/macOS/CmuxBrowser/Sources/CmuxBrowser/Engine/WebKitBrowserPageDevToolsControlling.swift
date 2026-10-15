import Foundation

/// Opens and closes Web Inspector for a WebKit page.
///
/// Web Inspector state is owned by the browser panel (attach/detach, dock
/// side, remembered visibility), so ``WebKitBrowserPage`` forwards its
/// developer tools calls here instead of driving the inspector itself.
@MainActor
public protocol WebKitBrowserPageDevToolsControlling: AnyObject {
    /// `true` while Web Inspector is open for the page.
    func isDeveloperToolsVisible() -> Bool
    /// Opens Web Inspector.
    /// - Returns: `true` when it opened or was already open.
    @discardableResult
    func showDeveloperTools() -> Bool
    /// Closes Web Inspector.
    /// - Returns: `true` when it closed or was already closed.
    @discardableResult
    func hideDeveloperTools() -> Bool
}
