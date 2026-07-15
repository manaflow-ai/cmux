import AppKit
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

    func webExtensionsPresentationSnapshot() async -> BrowserWebExtensionsPresentationSnapshot {
        guard #available(macOS 15.4, *), let webExtensionsManager else {
            return .unsupported
        }
        webExtensionsManager.startLoading()
        await webExtensionsManager.waitUntilLoaded()
        return webExtensionsManager.presentationSnapshot()
    }

    @discardableResult
    func openWebExtensionsDirectory() -> Bool {
        guard #available(macOS 15.4, *), let webExtensionsManager else { return false }
        do {
            try FileManager.default.createDirectory(
                at: webExtensionsManager.directory,
                withIntermediateDirectories: true
            )
            return NSWorkspace.shared.open(webExtensionsManager.directory)
        } catch {
#if DEBUG
            cmuxDebugLog("browser.extensions.open-directory.failed error=\(error)")
#endif
            return false
        }
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
