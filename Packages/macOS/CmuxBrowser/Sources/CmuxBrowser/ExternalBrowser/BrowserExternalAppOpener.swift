import AppKit
import CmuxSettings
public import Foundation

/// Opens web URLs in the configured external browser application.
@MainActor
public struct BrowserExternalAppOpener {
    /// Opens a URL with a resolved application and reports whether Launch Services accepted it.
    public typealias OpenWithApplication = @MainActor (URL, URL, Bool) -> Bool

    /// Resolves a configured application name, bundle identifier, or app path.
    public typealias ResolveApplication = @MainActor (String) -> URL?

    /// Opens a URL through the system handler and controls whether it activates the handler.
    public typealias OpenWithSystemDefault = @MainActor (URL, Bool) -> Bool

    /// Opens a URL through a resolved application and reports completion success.
    public typealias OpenWithApplicationAwaitingCompletion = @MainActor (URL, URL, Bool) async -> Bool

    /// Opens a URL through the system handler and reports completion success.
    public typealias OpenWithSystemDefaultAwaitingCompletion = @MainActor (URL, Bool) async -> Bool

    private let defaults: UserDefaults
    private let openWithApplication: OpenWithApplication
    private let resolveApplication: ResolveApplication
    private let openWithSystemDefault: OpenWithSystemDefault
    private let openWithApplicationAwaitingCompletion: OpenWithApplicationAwaitingCompletion
    private let openWithSystemDefaultAwaitingCompletion: OpenWithSystemDefaultAwaitingCompletion

    init(
        defaults: UserDefaults = .standard,
        openWithApplication: @escaping OpenWithApplication = Self.openWithApplication,
        resolveApplication: @escaping ResolveApplication = Self.resolveApplication,
        openWithSystemDefault: @escaping OpenWithSystemDefault = Self.openWithSystemDefault,
        openWithApplicationAwaitingCompletion: @escaping OpenWithApplicationAwaitingCompletion = Self.openWithApplicationAwaitingCompletion,
        openWithSystemDefaultAwaitingCompletion: @escaping OpenWithSystemDefaultAwaitingCompletion = Self.openWithSystemDefaultAwaitingCompletion
    ) {
        self.defaults = defaults
        self.openWithApplication = openWithApplication
        self.resolveApplication = resolveApplication
        self.openWithSystemDefault = openWithSystemDefault
        self.openWithApplicationAwaitingCompletion = openWithApplicationAwaitingCompletion
        self.openWithSystemDefaultAwaitingCompletion = openWithSystemDefaultAwaitingCompletion
    }

    /// Creates an opener that reads the browser choice from the supplied defaults.
    ///
    /// - Parameter defaults: The defaults domain containing the browser setting.
    public init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            openWithApplication: Self.openWithApplication,
            resolveApplication: Self.resolveApplication,
            openWithSystemDefault: Self.openWithSystemDefault,
            openWithApplicationAwaitingCompletion: Self.openWithApplicationAwaitingCompletion,
            openWithSystemDefaultAwaitingCompletion: Self.openWithSystemDefaultAwaitingCompletion
        )
    }

    /// Opens `url` in the configured application, falling back to Launch
    /// Services when the setting is empty or cannot be resolved.
    ///
    /// - Parameters:
    ///   - url: The destination URL.
    ///   - activates: Whether the target application may become active.
    /// - Returns: Whether Launch Services accepted the open request.
    @discardableResult
    public func open(_ url: URL, activates: Bool = true) -> Bool {
        // The preference selects a web browser. Keep non-web URLs (mailto,
        // file URLs, custom schemes) with their own Launch Services handlers.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return openWithSystemDefault(url, activates)
        }
        guard let identifier = BrowserExternalApplicationSettings(defaults: defaults).applicationIdentifier,
              let applicationURL = resolveApplication(identifier) else {
            return openWithSystemDefault(url, activates)
        }
        return openWithApplication(url, applicationURL, activates)
    }

    /// Opens a URL and waits for Launch Services to confirm delivery.
    ///
    /// - Parameters:
    ///   - url: The destination URL.
    ///   - activates: Whether the target application may become active.
    /// - Returns: Whether Launch Services reported a running application.
    public func openAwaitingCompletion(_ url: URL, activates: Bool = true) async -> Bool {
        // Keep non-web URLs with their own Launch Services handlers, just as
        // the synchronous API does.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return await openWithSystemDefaultAwaitingCompletion(url, activates)
        }
        guard let identifier = BrowserExternalApplicationSettings(defaults: defaults).applicationIdentifier,
              let applicationURL = resolveApplication(identifier) else {
            return await openWithSystemDefaultAwaitingCompletion(url, activates)
        }
        return await openWithApplicationAwaitingCompletion(url, applicationURL, activates)
    }

    private static let openWithApplication: OpenWithApplication = { url, applicationURL, activates in
        var options: NSWorkspace.LaunchOptions = []
        if !activates {
            options.insert(.withoutActivation)
        }
        do {
            _ = try NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                options: options,
                configuration: [:]
            )
            return true
        } catch {
            return false
        }
    }

    private static let openWithSystemDefault: OpenWithSystemDefault = { url, activates in
        guard !activates else { return NSWorkspace.shared.open(url) }
        var options: NSWorkspace.LaunchOptions = []
        options.insert(.withoutActivation)
        do {
            _ = try NSWorkspace.shared.open(url, options: options, configuration: [:])
            return true
        } catch {
            return false
        }
    }

    private static let openWithApplicationAwaitingCompletion: OpenWithApplicationAwaitingCompletion = { url, applicationURL, activates in
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activates
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { application, _ in
                continuation.resume(returning: application != nil)
            }
        }
    }

    private static let openWithSystemDefaultAwaitingCompletion: OpenWithSystemDefaultAwaitingCompletion = { url, activates in
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activates
            NSWorkspace.shared.open(url, configuration: configuration) { application, _ in
                continuation.resume(returning: application != nil)
            }
        }
    }

    private static let resolveApplication: ResolveApplication = { identifier in
        let expanded = NSString(string: identifier).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard url.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  Bundle(url: url) != nil else { return nil }
            return url
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return bundleURL
        }
        guard let applicationPath = NSWorkspace.shared.fullPath(forApplication: identifier) else {
            return nil
        }
        let url = URL(fileURLWithPath: applicationPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              Bundle(url: url) != nil else { return nil }
        return url
    }
}
