import Foundation

/// Process-wide browser services owned by the app composition root and injected
/// through window, workspace, and panel owners.
@MainActor
final class BrowserServices {
    private let webExtensionsManagerStorage: AnyObject?

    init(extensionDirectory: URL? = nil) {
        if #available(macOS 15.4, *) {
            webExtensionsManagerStorage = BrowserWebExtensionsManager(
                directory: extensionDirectory ?? Self.defaultExtensionDirectory
            )
        } else {
            webExtensionsManagerStorage = nil
        }
    }

    @available(macOS 15.4, *)
    var webExtensionsManager: BrowserWebExtensionsManager? {
        webExtensionsManagerStorage as? BrowserWebExtensionsManager
    }

    /// Starts browser-wide services before restored browser panels are created.
    func start() {
        BrowserSystemProxyWatcher.shared.startObserving()
        if #available(macOS 15.4, *) {
            webExtensionsManager?.startLoading()
        }
        BrowserPrewarmedWebViewPool.shared.configure(browserServices: self)
    }

    private static var defaultExtensionDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_EXTENSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/browser-extensions", isDirectory: true)
    }
}
