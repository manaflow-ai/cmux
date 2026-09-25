import AppKit
import CmuxSettings
import Foundation

/// Opens web URLs in the configured external browser application.
@MainActor
struct BrowserExternalAppOpener {
    typealias OpenWithApplication = @MainActor (URL, URL) -> Bool
    typealias ResolveApplication = @MainActor (String) -> URL?

    private let defaults: UserDefaults
    private let openWithApplication: OpenWithApplication
    private let resolveApplication: ResolveApplication
    private let openWithSystemDefault: @MainActor (URL) -> Bool

    init(
        defaults: UserDefaults = .standard,
        openWithApplication: @escaping OpenWithApplication = Self.openWithApplication,
        resolveApplication: @escaping ResolveApplication = Self.resolveApplication,
        openWithSystemDefault: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.openWithApplication = openWithApplication
        self.resolveApplication = resolveApplication
        self.openWithSystemDefault = openWithSystemDefault
    }

    /// Opens `url` in the configured application, falling back to Launch
    /// Services when the setting is empty or cannot be resolved.
    @discardableResult
    func open(_ url: URL) -> Bool {
        // The preference selects a web browser. Keep non-web URLs (mailto,
        // file URLs, custom schemes) with their own Launch Services handlers.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return openWithSystemDefault(url)
        }
        guard let identifier = BrowserExternalApplicationSettings(defaults: defaults).applicationIdentifier,
              let applicationURL = resolveApplication(identifier) else {
            return openWithSystemDefault(url)
        }
        return openWithApplication(url, applicationURL)
    }

    private static let openWithApplication: OpenWithApplication = { url, applicationURL in
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return true
    }

    private static let resolveApplication: ResolveApplication = { identifier in
        let expanded = NSString(string: identifier).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return bundleURL
        }
        guard let applicationPath = NSWorkspace.shared.fullPath(forApplication: identifier) else {
            return nil
        }
        return URL(fileURLWithPath: applicationPath, isDirectory: true)
    }
}
