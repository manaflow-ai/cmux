import Foundation
import WebKit
import ObjectiveC
import CmuxBrowser

/// Owns WebKit extension contexts for one cmux browser profile.
/// Controllers are intentionally profile-scoped so extension state is isolated
/// and survives pane recreation through the profile's website data store.
@available(macOS 15.4, *)
@MainActor
final class WebKitBrowserExtensionManager: NSObject {
    let controller: WKWebExtensionController?
    private(set) var loadError: Error?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?
    private var contexts: [WKWebExtensionContext] = []
    /// Loading tasks are retained until completion so a pane created during
    /// startup cannot drop its service worker before the first navigation.
    private var loadTasks: [Task<Void, Never>] = []

    init(profileID: UUID, websiteDataStore: WKWebsiteDataStore, directories: [URL]) {
        guard !directories.isEmpty else {
            controller = nil
            super.init()
            return
        }
        let configuration = WKWebExtensionController.Configuration(identifier: profileID)
        configuration.defaultWebsiteDataStore = websiteDataStore
        let controller = WKWebExtensionController(configuration: configuration)
        self.controller = controller
        super.init()
        controller.delegate = self
        for directory in directories {
            let task = Task { @MainActor [weak self, weak controller] in
                do {
                    let webExtension = try await WKWebExtension(resourceBaseURL: directory)
                    let context = WKWebExtensionContext(for: webExtension)
                    self?.contexts.append(context)
                    try controller?.load(context)
                    self?.onReady?()
                } catch {
                    let diagnostic = ChromiumExtensionError(path: directory.path, reason: error.localizedDescription)
                    self?.loadError = diagnostic
                    self?.onError?(diagnostic.localizedDescription)
                }
            }
            loadTasks.append(task)
        }
    }


    private static var associationKey: UInt8 = 0

    static func retain(_ manager: WebKitBrowserExtensionManager, on configuration: WKWebViewConfiguration) {
        objc_setAssociatedObject(configuration, &associationKey, manager, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func retain(_ manager: WebKitBrowserExtensionManager, on webView: WKWebView) {
        objc_setAssociatedObject(webView, &associationKey, manager, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func manager(for configuration: WKWebViewConfiguration) -> WebKitBrowserExtensionManager? {
        objc_getAssociatedObject(configuration, &associationKey) as? WebKitBrowserExtensionManager
    }

    static func manager(for webView: WKWebView) -> WebKitBrowserExtensionManager? {
        objc_getAssociatedObject(webView, &associationKey) as? WebKitBrowserExtensionManager
    }

    deinit {
        loadTasks.forEach { $0.cancel() }
    }
}

@available(macOS 15.4, *)
extension WebKitBrowserExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}
