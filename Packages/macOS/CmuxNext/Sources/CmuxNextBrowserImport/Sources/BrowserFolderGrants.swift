public import Foundation
import os

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
    private let bookmarks = OSAllocatedUnfairLock(initialState: [String: Data]())

    public init() {}

    public func bookmark(for browser: String) -> Data? { bookmarks.withLock { $0[browser] } }
    public func setBookmark(_ data: Data?, for browser: String) { bookmarks.withLock { $0[browser] = data } }
}

/// Import from Browser reads a browser's profiles only after the person
/// picked that browser's data folder in the open panel (Zen's flow). The pick
/// is kept as a security-scoped bookmark per browser, so the next import asks
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
        // A security-scoped bookmark where the process can make one; a plain one otherwise
        // (an unsandboxed process may not hold the scope, and needs none to read).
        let data = (try? picked.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else { throw GrantError.bookmarkFailed }
        store.setBookmark(data, for: browser.rawValue)
    }

    /// Forgets the grant; the browser asks again.
    public func revoke(_ browser: ImportBrowser) {
        store.setBookmark(nil, for: browser.rawValue)
    }

    /// The granted folder, when the kept bookmark still resolves to `browser`'s data folder.
    public func grantedFolder(_ browser: ImportBrowser) -> URL? {
        guard let data = store.bookmark(for: browser.rawValue) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url, accepts(url, for: browser) else { return nil }
        return url
    }

    public func isGranted(_ browser: ImportBrowser) -> Bool { !needsGrant(browser) || grantedFolder(browser) != nil }

    /// Browsers whose data folder is on this Mac without a grant, one per
    /// folder (Zen and Zen Twilight share one), in registry order. Only the
    /// folder's existence is checked.
    public func awaiting(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [ImportBrowser] {
        var seen = Set<String>()
        return browsers.filter { browser in
            guard !Task.isCancelled, needsGrant(browser) else { return false }
            let directory = folder(browser)
            guard FileManager.default.fileExists(atPath: directory.path), seen.insert(Self.canonicalPath(directory)).inserted else { return false }
            return grantedFolder(browser) == nil
        }
    }

    /// Detection over the browsers that need no grant and the granted ones.
    public func detect(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [BrowserSource] {
        // Stops resolving grants once the scan is cancelled (the import window closed).
        let readable = browsers.filter { !Task.isCancelled && isGranted($0) }
        // Each granted folder is resolved and opened one at a time, so a cancelled scan
        // (the import window closed) stops at the next bookmark instead of resolving them all.
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for browser in readable {
            guard !Task.isCancelled else { return [] }
            if let folder = grantedFolder(browser), folder.startAccessingSecurityScopedResource() { scoped.append(folder) }
        }
        guard !Task.isCancelled else { return [] }
        return BrowserSourceDetector(environment: environment).detect(readable)
    }

    /// Runs `body` with every granted folder of `browsers` in scope.
    public func accessing<T>(_ browsers: [ImportBrowser], _ body: () throws -> T) rethrows -> T {
        let scoped = browsers.compactMap(grantedFolder).filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
