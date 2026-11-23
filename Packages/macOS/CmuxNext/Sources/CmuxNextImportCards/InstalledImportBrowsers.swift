public import AppKit
public import CmuxNextBrowserImport

/// The browsers on this Mac that cmux can import from, with their apps, in
/// offer order (Launch Services only: no file of the browser is read). The
/// Import from Browser offer in the browser toolbar lists these.
public nonisolated struct InstalledImportBrowsers: Sendable {
    /// The browsers people most often come from lead; the rest keep registry order.
    public static let leading: [ImportBrowser] = [.chrome, .edge, .firefox, .arc, .brave, .safari]

    /// Launch Services' app for a bundle id.
    public var appURL: @Sendable (String) -> URL?

    public init(appURL: @escaping @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.appURL = appURL
    }

    /// The installed browsers and their apps, in offer order (any thread).
    public func locate() -> [(browser: ImportBrowser, app: URL)] {
        // Browsers, and apps that keep a browser profile (Claude, the ChatGPT app); WebKit
        // apps import their cookies from WebKit's store (Orion, ChatGPT Classic).
        let candidates = ImportBrowser.allCases.filter { browser in
            [.browser, .appWithEmbeddedBrowser].contains(browser.kind) && !browser.refusesSessionData
                && [.chromium, .firefox, .safari, .webkit].contains(browser.family)
        }
        let rank = { (browser: ImportBrowser) in Self.leading.firstIndex(of: browser) ?? Self.leading.count }
        return candidates.sorted { rank($0) < rank($1) }.compactMap { browser in
            browser.bundleIDs.compactMap(appURL).first.map { (browser: browser, app: $0) }
        }
    }
}

/// A browser on this Mac that cmux can import from, with its app icon
/// (``InstalledImportBrowsers`` finds them).
public struct InstalledImportBrowser {
    public let browser: ImportBrowser
    public let icon: NSImage

    public init(browser: ImportBrowser, icon: NSImage) {
        self.browser = browser
        self.icon = icon
    }
}

/// Finds the installed browsers once per launch, off the main thread, for the Import Cookies banner.
@MainActor
public final class InstalledImportBrowserFinder {
    /// Browsers cmux can import from, most used first; nil until found.
    public private(set) var browsers: [InstalledImportBrowser]?
    private var finding: Task<Void, Never>?
    private var waiting: [@MainActor ([InstalledImportBrowser]) -> Void] = []
    /// Finds the installed browsers' apps (any thread); tests pass their own.
    private let locate: @Sendable () -> [(browser: ImportBrowser, app: URL)]

    public init(locate: @escaping @Sendable () -> [(browser: ImportBrowser, app: URL)] = { InstalledImportBrowsers().locate() }) {
        self.locate = locate
    }

    /// Calls `done` with the installed browsers: at once when they are known, else after the one
    /// Launch Services lookup.
    public func find(then done: (@MainActor ([InstalledImportBrowser]) -> Void)? = nil) {
        if let browsers { done?(browsers); return }
        if let done { waiting.append(done) }
        guard finding == nil else { return }
        // task-owner: one Launch Services lookup per launch; ends after it
        finding = Task { [weak self, locate] in
            let apps = await Task.detached { locate() }.value
            let found = apps.map { InstalledImportBrowser(browser: $0.browser, icon: NSWorkspace.shared.icon(forFile: $0.app.path)) }
            guard let self else { return }
            browsers = found
            finding = nil
            let callbacks = waiting
            waiting = []
            for callback in callbacks { callback(found) }
        }
    }
}
