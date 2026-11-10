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
/// The default read is bounded. It follows the file's own page table, reads
/// the header, the table and the pages, and stops there: the trailer after the
/// last page is never loaded, so its size cannot count against the store. A
/// store whose header, table and pages exceed ``maximumStoreBytes`` is
/// reported as ``SafariCookieStoreLoad/tooLarge(url:)`` after at most that many
/// bytes, plus one, have been read.
///
/// ```swift
/// let reader = SafariCookieStoreReader(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
/// if case .loaded(_, let data) = reader.load(for: profile) {
///     let cookies = try SafariBinaryCookiesParser().parse(data)
/// }
/// ```
public struct SafariCookieStoreReader: Sendable {
    /// Reads one store's bytes; replaced in tests to reach every error path.
    /// Throws ``StoreTooLarge`` for a store it refuses to load for its size.
    public typealias DataReader = @Sendable (URL) throws -> Data

    /// Thrown by a ``DataReader`` when a store holds more page data than it will load.
    public struct StoreTooLarge: Error, Equatable, Sendable {
        /// Creates the error; it carries no detail because the reader reports the store's URL.
        public init() {}
    }

    private static let storeFileName = "Cookies.binarycookies"
    private static let magic = Array("cook".utf8)
    private static let headerSize = 8

    /// The most bytes of header, page table and pages the default read loads from one store.
    public let maximumStoreBytes: Int

    private let homeDirectory: URL
    private let readData: DataReader

    /// Creates a reader rooted at a home directory.
    ///
    /// - Parameters:
    ///   - homeDirectory: The user's home, which the default profile's store
    ///     paths are relative to and which ``displayPath(for:)`` abbreviates.
    ///   - maximumStoreBytes: The limit for the default read. The default of
    ///     128 MiB is twice the parser's default decode limit, which leaves
    ///     room for page headers and offset tables, so a store the parser
    ///     would decode is not refused here. An injected `readData` applies
    ///     its own limit, if any.
    ///   - readData: Reads one store. Defaults to the bounded read described
    ///     on the type.
    public init(
        homeDirectory: URL,
        maximumStoreBytes: Int = 128 << 20,
        readData: DataReader? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.maximumStoreBytes = maximumStoreBytes
        self.readData = readData ?? { try Self.readPagedRegion(of: $0, maximumBytes: maximumStoreBytes) }
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
            } catch is StoreTooLarge {
                return .tooLarge(url: candidate)
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

    /// Reads a store's header, page table and pages, and nothing after them.
    ///
    /// The page table says how long the paged region is, so the read never
    /// depends on the file's size. A file that ends early, or does not start
    /// with the magic number, is returned as far as it was read: the parser
    /// then reports it as damaged. Only bytes that are really in the file
    /// count against `maximumBytes`, so a small file whose header overstates
    /// its pages is not mistaken for a large store.
    ///
    /// - Throws: ``StoreTooLarge`` when the paged region holds more than
    ///   `maximumBytes`, or the error from opening or reading the file.
    static func readPagedRegion(of url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        guard try append(headerSize, from: handle, to: &data, maximumBytes: maximumBytes),
              data.prefix(magic.count).elementsEqual(magic) else {
            return data
        }
        let pageCount = Int(bigEndianUInt32(in: data, at: 4))
        guard try append(pageCount * 4, from: handle, to: &data, maximumBytes: maximumBytes) else {
            return data
        }
        var pageBytes = 0
        for pageIndex in 0..<pageCount {
            pageBytes += Int(bigEndianUInt32(in: data, at: headerSize + pageIndex * 4))
        }
        _ = try append(pageBytes, from: handle, to: &data, maximumBytes: maximumBytes)
        return data
    }

    /// Appends the next `count` bytes of `handle` to `data`, never growing it past `maximumBytes`.
    ///
    /// - Returns: `false` when the file ended before `count` bytes were read.
    /// - Throws: ``StoreTooLarge`` when `count` bytes do not fit under
    ///   `maximumBytes` and the file holds at least one byte past it.
    private static func append(
        _ count: Int,
        from handle: FileHandle,
        to data: inout Data,
        maximumBytes: Int
    ) throws -> Bool {
        let allowed = min(count, max(0, maximumBytes - data.count))
        var remaining = allowed
        while remaining > 0, let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty {
            data.append(chunk)
            remaining -= chunk.count
        }
        guard remaining == 0 else { return false }
        guard allowed < count else { return true }
        if let next = try handle.read(upToCount: 1), !next.isEmpty {
            throw StoreTooLarge()
        }
        return false
    }

    /// The big-endian `UInt32` at `offset` in `data`, which the caller has checked holds it.
    private static func bigEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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
