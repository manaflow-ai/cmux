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
        let candidates = ImportBrowser.allCases.filter { browser in
            browser.kind == .browser && !browser.refusesSessionData && [.chromium, .firefox, .safari].contains(browser.family)
        }
        let rank = { (browser: ImportBrowser) in Self.leading.firstIndex(of: browser) ?? Self.leading.count }
        return candidates.sorted { rank($0) < rank($1) }.compactMap { browser in
            browser.bundleIDs.compactMap(appURL).first.map { (browser: browser, app: $0) }
        }
    }
}
