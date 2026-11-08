public import Foundation

/// Locates and reads the `Cookies.binarycookies` store behind a Safari source profile.
///
/// The default profile's store lives in Safari's sandbox container on current
/// macOS and in `~/Library/Cookies` on systems that predate the sandbox. A named
/// profile keeps its store in the directory the browser detector reported for
/// it; the detector recognizes a WebKit profile directory by that same file.
///
/// Candidates are read in order, and the next one is tried only when the
/// current one is confirmed absent. A store that exists but is denied (Full
/// Disk Access) or unreadable is reported for its own path instead of being
/// silently replaced by an older copy or by "not found".
///
/// ```swift
/// let reader = SafariCookieStoreReader(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
/// if case .loaded(_, let data) = reader.load(for: profile) {
///     let cookies = try SafariBinaryCookiesParser().parse(data)
/// }
/// ```
public struct SafariCookieStoreReader: Sendable {
    /// Reads a file's full contents; replaced in tests to reach every error path.
    public typealias DataReader = @Sendable (URL) throws -> Data

    private static let storeFileName = "Cookies.binarycookies"

    private let homeDirectory: URL
    private let readData: DataReader

    /// Creates a reader rooted at a home directory.
    ///
    /// - Parameters:
    ///   - homeDirectory: The user's home, which the default profile's store
    ///     paths are relative to and which ``displayPath(for:)`` abbreviates.
    ///   - readData: Reads one file. Defaults to `Data(contentsOf:)`.
    public init(
        homeDirectory: URL,
        readData: @escaping DataReader = { try Data(contentsOf: $0) }
    ) {
        self.homeDirectory = homeDirectory
        self.readData = readData
    }

    /// The store paths tried for `profile`, in order.
    public func candidateURLs(for profile: InstalledBrowserProfile) -> [URL] {
        guard profile.isDefault else {
            return [profile.rootURL.appendingPathComponent(Self.storeFileName, isDirectory: false)]
        }
        return [
            homeDirectory.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Cookies/\(Self.storeFileName)",
                isDirectory: false
            ),
            homeDirectory.appendingPathComponent("Library/Cookies/\(Self.storeFileName)", isDirectory: false),
        ]
    }

    /// Reads the first candidate store that exists for `profile`.
    public func load(for profile: InstalledBrowserProfile) -> SafariCookieStoreLoad {
        for candidate in candidateURLs(for: profile) {
            do {
                return .loaded(url: candidate, data: try readData(candidate))
            } catch {
                switch SafariCookieStoreErrorKind(classifying: error) {
                case .missing:
                    continue
                case .permissionDenied(let cause):
                    return .accessDenied(url: candidate, cause: cause)
                case .other:
                    return .unreadable(url: candidate)
                }
            }
        }
        return .missing
    }

    /// `url`'s path for a warning: under the home directory it starts with `~/`,
    /// so a warning pasted into a bug report does not carry the account name.
    public func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        var home = homeDirectory.standardizedFileURL.path
        if !home.hasSuffix("/") {
            home += "/"
        }
        guard path.hasPrefix(home) else { return path }
        return "~/" + path.dropFirst(home.count)
    }
}
