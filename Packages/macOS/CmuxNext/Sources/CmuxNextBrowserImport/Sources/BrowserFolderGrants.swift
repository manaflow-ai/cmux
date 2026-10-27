import CmuxNextCompat
public import Foundation

/// Where folder grants are kept: one bookmark per browser id.
public protocol BrowserFolderGrantStore: AnyObject, Sendable {
    func bookmark(for browser: String) -> Data?
    func setBookmark(_ data: Data?, for browser: String)
}

/// Grants in the app's defaults (`browserImport.folderGrant.<browser>`).
public final class UserDefaultsBrowserFolderGrantStore: BrowserFolderGrantStore {
    /// nil: the standard defaults. A suite name, not a `UserDefaults`, which is not `Sendable`.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func bookmark(for browser: String) -> Data? { defaults.data(forKey: Self.key(browser)) }
    public func setBookmark(_ data: Data?, for browser: String) { defaults.set(data, forKey: Self.key(browser)) }
    private static func key(_ browser: String) -> String { "browserImport.folderGrant.\(browser)" }
}

/// Grants held in memory (tests, and a launch that must not persist them).
public final class MemoryBrowserFolderGrantStore: BrowserFolderGrantStore {
    private let bookmarks = Mutex<[String: Data]>([:])

    public init() {}

    public func bookmark(for browser: String) -> Data? { bookmarks.withLock { $0[browser] } }
    public func setBookmark(_ data: Data?, for browser: String) { bookmarks.withLock { $0[browser] = data } }
}

/// Import from Browser reads a browser's profiles only after the person
/// picked that browser's data folder in the open panel (Zen's flow). The pick
/// is kept as a security-scoped bookmark per browser (the path on Linux: ``FolderBookmark``), so the next import asks
/// nothing. Before a grant, the browser is only listed (its folder exists);
/// nothing inside it is opened. Safari keeps the Full Disk Access path: its
/// data sits in a protected container, not one profile folder.
public struct BrowserFolderGrants: Sendable {
    public var environment: ImportEnvironment
    public let store: any BrowserFolderGrantStore

    public enum GrantError: Error, Equatable {
        /// The picked folder is not the browser's data folder.
        case wrongFolder(expected: URL)
        /// macOS made no bookmark for it.
        case bookmarkFailed
    }

    public init(environment: ImportEnvironment, store: any BrowserFolderGrantStore) {
        self.environment = environment
        self.store = store
    }

    /// Whether `browser` is read through a folder grant (Chromium and Firefox
    /// families); the others keep their own path.
    public func needsGrant(_ browser: ImportBrowser) -> Bool {
        browser.row != nil && (browser.family == .chromium || browser.family == .firefox)
    }

    /// The folder the open panel starts in, and the only one a grant accepts.
    public func folder(_ browser: ImportBrowser) -> URL { environment.dataDirectory(browser) }

    /// Whether `picked` is `browser`'s data folder (symlinks and a trailing slash aside).
    public func accepts(_ picked: URL, for browser: ImportBrowser) -> Bool {
        Self.canonicalPath(picked) == Self.canonicalPath(folder(browser))
    }

    /// Keeps the person's pick of `browser`'s folder.
    public func grant(_ picked: URL, for browser: ImportBrowser) throws {
        guard accepts(picked, for: browser) else { throw GrantError.wrongFolder(expected: folder(browser)) }
        guard let data = FolderBookmark.make(picked) else { throw GrantError.bookmarkFailed }
        store.setBookmark(data, for: browser.rawValue)
    }

    /// Forgets the grant; the browser asks again.
    public func revoke(_ browser: ImportBrowser) {
        store.setBookmark(nil, for: browser.rawValue)
    }

    /// The granted folder, when the kept bookmark still resolves to `browser`'s data folder.
    public func grantedFolder(_ browser: ImportBrowser) -> URL? {
        guard let data = store.bookmark(for: browser.rawValue), let url = FolderBookmark.resolve(data),
              accepts(url, for: browser) else { return nil }
        return url
    }

    public func isGranted(_ browser: ImportBrowser) -> Bool { !needsGrant(browser) || grantedFolder(browser) != nil }

    /// Browsers whose data folder is on this Mac without a grant, one per
    /// folder (Zen and Zen Twilight share one), in registry order. Only the
    /// folder's existence is checked.
    public func awaiting(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [ImportBrowser] {
        var seen = Set<String>()
        return browsers.filter { browser in
            guard needsGrant(browser) else { return false }
            let directory = folder(browser)
            guard FileManager.default.fileExists(atPath: directory.path), seen.insert(Self.canonicalPath(directory)).inserted else { return false }
            return grantedFolder(browser) == nil
        }
    }

    /// Detection over the browsers that need no grant and the granted ones.
    public func detect(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [BrowserSource] {
        let readable = browsers.filter(isGranted)
        return accessing(readable) { BrowserSourceDetector(environment: environment).detect(readable) }
    }

    /// Runs `body` with every granted folder of `browsers` in scope.
    public func accessing<T>(_ browsers: [ImportBrowser], _ body: () throws -> T) rethrows -> T {
        try FolderBookmark.accessing(browsers.compactMap(grantedFolder), body)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
