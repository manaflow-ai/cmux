public import Foundation

/// A browser or password manager whose export steps Import from Another Browser… shows.
///
/// One row of the bundled `browser-export-steps.json`. The steps' text follows ``family``; a Chromium
/// browser's row names the pages it exports from. Nothing here names a file of the browser's own: this
/// import reads only the files the person exports, so it ships in every build (cx-f58x).
public nonisolated struct BrowserExportSource: Decodable, Equatable, Sendable {
    /// Which export steps a row shows.
    public enum Family: String, Decodable, Sendable {
        /// Chrome and its forks: password and bookmark export pages.
        case chromium
        /// Firefox and its forks.
        case firefox
        /// Safari and the Passwords app.
        case safari
        /// 1Password: passwords only.
        case onePassword = "1password"
        /// Bitwarden: passwords only.
        case bitwarden
    }

    /// A stable id, such as `helium`.
    public let id: String
    /// A product name, not translated.
    public let name: String
    /// Which export steps the row shows.
    public let family: Family
    /// The app's bundle ids, to find it on this Mac with Launch Services (nothing of the app is read).
    public let bundleIDs: [String]
    /// The page that exports passwords (Chromium browsers).
    public let passwords: String?
    /// The page that exports bookmarks (Chromium browsers); nil when it has no bookmarks export (Arc).
    public let bookmarks: String?
    /// Where its history exports (Chrome: Google Takeout).
    public let history: String?

    /// A row, as the bundled file holds it.
    ///
    /// - Parameters:
    ///   - id: A stable id.
    ///   - name: The product name.
    ///   - family: Which export steps the row shows.
    ///   - bundleIDs: The app's bundle ids.
    ///   - passwords: The password export page, if any.
    ///   - bookmarks: The bookmark export page, if any.
    ///   - history: Where history exports, if anywhere.
    public init(id: String, name: String, family: Family, bundleIDs: [String],
                passwords: String?, bookmarks: String?, history: String?) {
        self.id = id
        self.name = name
        self.family = family
        self.bundleIDs = bundleIDs
        self.passwords = passwords
        self.bookmarks = bookmarks
        self.history = history
    }

    /// The rows of an export-steps file (`{"browsers": [...]}`), in the order the picker lists them.
    ///
    /// The App bundles the file (`browser-export-steps.json`) and passes its contents here.
    /// - Parameter data: The file's contents.
    /// - Returns: The rows; empty when `data` is not such a file.
    public static func rows(in data: Data) -> [BrowserExportSource] {
        struct File: Decodable { let browsers: [BrowserExportSource] }
        return (try? JSONDecoder().decode(File.self, from: data))?.browsers ?? []
    }
}
