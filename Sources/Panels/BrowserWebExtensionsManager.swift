import Foundation
import WebKit

/// Loads Safari Web Extensions (WebExtension `manifest.json` bundles, the same
/// format Safari and Chrome use) into every cmux browser webview.
///
/// Extensions are installed by dropping an unpacked extension directory (or a
/// `.zip` of one) into `~/.config/cmux/browser-extensions/`. Each entry must
/// contain a `manifest.json` at its root. Extensions are discovered once at app
/// launch; add or remove entries and relaunch cmux to apply.
///
/// Installing an extension into the directory is treated as consent: every
/// permission and host match pattern the manifest requests is granted at load,
/// and runtime requests for optional permissions are granted without prompting.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionsManager: NSObject {
    /// Fixed controller identifier so extension storage (`browser.storage`,
    /// declarativeNetRequest state) persists across launches.
    private static let controllerIdentifier = UUID(uuidString: "3B7D2A9E-5C41-4F8A-B6D0-9E2C7A51F3D8")!

    /// `CMUX_BROWSER_EXTENSIONS_DIR` overrides the default location so tagged
    /// dev builds can dogfood against an isolated directory.
    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_EXTENSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/browser-extensions", isDirectory: true)
    }

    /// Non-nil only when the extensions directory contains at least one
    /// candidate at launch, so installs without extensions pay no cost.
    static let shared: BrowserWebExtensionsManager? = {
        let directory = defaultDirectory
        guard !candidateURLs(in: directory).isEmpty else { return nil }
        let manager = BrowserWebExtensionsManager(directory: directory)
        manager.loadTask = Task { await manager.loadExtensions() }
        return manager
    }()

    let controller: WKWebExtensionController
    let directory: URL
    var loadTask: Task<Void, Never>?
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var loadErrors: [(url: URL, error: any Error)] = []

    init(directory: URL, controllerConfiguration: WKWebExtensionController.Configuration? = nil) {
        self.directory = directory
        let configuration = controllerConfiguration
            ?? WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        self.controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// Directories and `.zip` archives directly inside `directory`. Hidden
    /// entries are skipped so `.DS_Store` and dotfiles never surface as errors.
    nonisolated static func candidateURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { url in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    return true
                }
                return url.pathExtension.lowercased() == "zip"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadExtensions() async {
        for url in Self.candidateURLs(in: directory) {
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: url)
                let context = WKWebExtensionContext(for: webExtension)
                // Stable identifier derived from the install-directory name so
                // per-extension storage survives relaunches.
                context.uniqueIdentifier = "cmux-browser-extension-\(url.lastPathComponent)"
                context.isInspectable = true
                grantRequestedPermissions(in: context, for: webExtension)
                try controller.load(context)
                loadedContexts.append(context)
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.loaded name=\(webExtension.displayName ?? url.lastPathComponent) " +
                    "permissions=\(webExtension.requestedPermissions.count) " +
                    "patterns=\(webExtension.requestedPermissionMatchPatterns.count)"
                )
#endif
            } catch {
                loadErrors.append((url: url, error: error))
#if DEBUG
                cmuxDebugLog("browser.extensions.load-failed entry=\(url.lastPathComponent) error=\(error)")
#endif
            }
        }
    }

    private func grantRequestedPermissions(in context: WKWebExtensionContext, for webExtension: WKWebExtension) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }
}

@available(macOS 15.4, *)
extension BrowserWebExtensionsManager: WKWebExtensionControllerDelegate {
    // Runtime permission requests are granted without prompting, but only for
    // what the manifest declares (`permissions`/`host_permissions` plus
    // `optional_permissions`/`optional_host_permissions`); installing the
    // extension is the consent gate for exactly that declared set. Anything
    // outside the manifest is denied.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let declared = extensionContext.webExtension.requestedPermissions
            .union(extensionContext.webExtension.optionalPermissions)
        completionHandler(permissions.intersection(declared), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let declared = Self.declaredMatchPatterns(of: extensionContext.webExtension)
        let allowed = urls.filter { url in declared.contains { $0.matches(url) } }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let declared = Self.declaredMatchPatterns(of: extensionContext.webExtension)
        let allowed = matchPatterns.filter { requested in declared.contains { $0.matches(requested) } }
        completionHandler(allowed, nil)
    }

    private static func declaredMatchPatterns(of webExtension: WKWebExtension) -> Set<WKWebExtension.MatchPattern> {
        webExtension.requestedPermissionMatchPatterns
            .union(webExtension.optionalPermissionMatchPatterns)
    }
}
