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

    func installWebExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        guard #available(macOS 15.4, *), let webExtensionsManager else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager.installExtension(from: source)
    }

    func installWebExtension(_ entry: BrowserWebExtensionCatalogEntry) async throws -> BrowserWebExtensionInstallReceipt {
        guard #available(macOS 15.4, *), let webExtensionsManager else {
            throw BrowserWebExtensionServiceError.unsupported
        }
        return try await webExtensionsManager.installCatalogExtension(entry)
    }

    func registerBrowserPanel(_ panel: BrowserPanel, workspace: Workspace) {
        guard #available(macOS 15.4, *), let webExtensionsManager else { return }
        webExtensionsManager.register(panel: panel, workspace: workspace)
    }

    func unregisterBrowserPanel(id: UUID) {
        guard #available(macOS 15.4, *), let webExtensionsManager else { return }
        webExtensionsManager.unregister(panelID: id)
    }

    func performWebExtensionAction(uniqueIdentifier: String, in panel: BrowserPanel) -> Bool {
        guard #available(macOS 15.4, *), let webExtensionsManager else { return false }
        return webExtensionsManager.performAction(uniqueIdentifier: uniqueIdentifier, in: panel)
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

struct BrowserWebExtensionInstallReceipt: Equatable, Sendable {
    let name: String
}

enum BrowserWebExtensionServiceError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        String(
            localized: "browser.extensions.unsupported",
            defaultValue: "Browser extensions require macOS 15.4 or later."
        )
    }
}
