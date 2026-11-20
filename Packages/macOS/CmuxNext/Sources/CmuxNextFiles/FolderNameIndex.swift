public import Foundation
import Darwin

/// A name index over one folder tree: the Files pane's "search this folder" (Finder's search
/// field, by name), without Spotlight.
///
/// One `fts(3)` walk stores every name once, folded (case and accents), in one contiguous byte
/// buffer; a search is one `memmem` pass over that buffer, so 100 000 files are searched in
/// about a millisecond, in folders Spotlight never indexed (`/tmp`, external disks, excluded
/// paths) too. Like Finder's search it skips hidden items and the inside of packages.
///
/// The value is immutable and `Sendable`: build it off the main thread, search it anywhere, and
/// build a new one when the tree changes. See plans/cmux-next/files-finder-parity-DESIGN.md, 4.2.
///
/// ```swift
/// let index = try await Task.detached { try FolderNameIndex.build(root: folder) }.value
/// let hits = index.search("report")   // exact, prefix, word start, then substring matches
/// ```
public struct FolderNameIndex: Sendable {
    /// One item a search found.
    public struct Hit: Sendable, Equatable {
        /// The item's path below the root (`docs/Report.pdf`).
        public let relativePath: String
        /// The item's file URL.
        public let url: URL
        /// Whether the item is a directory (a folder or a package).
        public let isDirectory: Bool
        /// The item's name (the last component of ``relativePath``).
        public var name: String { (relativePath as NSString).lastPathComponent }
    }

    /// The folder the index covers.
    public let root: URL
    /// How many items it holds.
    public var count: Int { paths.count }
    /// True when the walk stopped at the entry limit (search then misses the rest).
    public let truncated: Bool

    private let paths: [String]
    private let directories: [Bool]
    /// Every folded name, each followed by a 0 byte.
    private let folded: [UInt8]
    /// Where each item's folded name starts in ``folded`` (ascending), plus the buffer's end.
    private let starts: [UInt32]

    /// Walks `root` and indexes every name below it.
    ///
    /// - Parameters:
    ///   - root: the folder to index; it must exist.
    ///   - includeHidden: also index names that start with a dot and what is inside them (Finder's
    ///     search does not: false).
    ///   - entryLimit: stop after this many items and set ``truncated`` (memory bound: about 60
    ///     bytes per item).
    ///   - skippingFolders: folder names neither indexed nor walked into (`node_modules`), so
    ///     generated trees do not spend the entry limit. Empty by default.
    /// - Throws: ``FileBrowserError`` when `root` cannot be read.
    public static func build(root: URL, includeHidden: Bool = false, entryLimit: Int = 2_000_000,
                             skippingFolders: Set<String> = []) throws -> FolderNameIndex {
        let rootPath = root.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileBrowserError.missing(root)
        }
        var builder = Builder()
        let truncated = try rootPath.withCString { cPath -> Bool in
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
            defer { argv.deallocate() }
            let copy = strdup(cPath)
            defer { free(copy) }
            argv[0] = copy
            argv[1] = nil
            // FTS_NOSTAT: directory-ness comes from d_type, so no stat per file.
            guard let stream = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else {
                throw FileBrowserError.unreadable(root, errno)
            }
            defer { fts_close(stream) }
            let prefixLength = rootPath == "/" ? 1 : rootPath.utf8.count + 1
            while let entry = fts_read(stream) {
                let info = Int32(entry.pointee.fts_info)
                if entry.pointee.fts_level == 0 { continue }
                if info == FTS_DP { continue }
                let full = String(cString: entry.pointee.fts_path)
                let name = (full as NSString).lastPathComponent
                let isDir = info == FTS_D || info == FTS_DC || info == FTS_DOT
                if !includeHidden, name.hasPrefix(".") {
                    if isDir { fts_set(stream, entry, FTS_SKIP) }
                    continue
                }
                if isDir, skippingFolders.contains(name) {
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
                if builder.count >= entryLimit { return true }
                builder.add(relative: String(full.utf8.dropFirst(prefixLength)) ?? name, name: name, isDirectory: isDir)
                if isDir, FileOpenKind.packageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    fts_set(stream, entry, FTS_SKIP)
                }
            }
            return false
        }
        return FolderNameIndex(root: URL(fileURLWithPath: rootPath, isDirectory: true), truncated: truncated, builder: builder)
    }

    private init(root: URL, truncated: Bool, builder: Builder) {
        self.root = root
        self.truncated = truncated
        paths = builder.paths
        directories = builder.directories
        folded = builder.folded
        starts = builder.starts + [UInt32(builder.folded.count)]
    }

    /// The items whose name contains `query` (case and accents ignored), best first: the exact
    /// name, then names that start with it, then a word inside the name that starts with it,
    /// then any other match; shorter names first within each group. Empty for an empty query.
    ///
    /// - Parameters:
    ///   - query: the typed text.
    ///   - limit: the most hits returned.
    public func search(_ query: String, limit: Int = 200) -> [Hit] {
        let needle = Self.fold(query)
        guard !needle.isEmpty, limit > 0, !paths.isEmpty else { return [] }
        // Four rank buckets, each capped at `limit`: a common query stops collecting the worse
        // buckets early instead of sorting every match.
        var buckets: [[Int]] = [[], [], [], []]
        var lastItem = -1
        folded.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress else { return }
                var offset = 0
                while offset + needle.count <= hay.count {
                    guard let found = memmem(base + offset, hay.count - offset, pinBase, needle.count) else { break }
                    let at = base.distance(to: UnsafePointer(found.assumingMemoryBound(to: UInt8.self)))
                    let item = itemIndex(containing: at)
                    if item != lastItem {
                        lastItem = item
                        let start = Int(starts[item]), end = Int(starts[item + 1]) - 1
                        let rank: Int
                        if at == start { rank = at + needle.count == end ? 0 : 1 }
                        else { rank = Self.isWordStart(base, at, start) ? 2 : 3 }
                        if buckets[rank].count < limit { buckets[rank].append(item) }
                        if buckets[0].count >= limit { break }
                        // Move to the next name: one item counts once.
                        offset = end + 1
                    } else {
                        offset = at + 1
                    }
                }
            }
        }
        var hits: [Hit] = []
        hits.reserveCapacity(limit)
        for bucket in buckets {
            let ordered = bucket.sorted { lhs, rhs in
                let l = starts[lhs + 1] - starts[lhs], r = starts[rhs + 1] - starts[rhs]
                return l != r ? l < r : paths[lhs].utf8.count < paths[rhs].utf8.count
            }
            for item in ordered {
                guard hits.count < limit else { return hits }
                hits.append(Hit(relativePath: paths[item], url: root.appendingPathComponent(paths[item], isDirectory: directories[item]),
                                isDirectory: directories[item]))
            }
        }
        return hits
    }

    /// The item whose folded name holds byte `offset` (binary search over ``starts``).
    private func itemIndex(containing offset: Int) -> Int {
        var low = 0, high = starts.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(starts[mid]) <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func isWordStart(_ base: UnsafePointer<UInt8>, _ at: Int, _ start: Int) -> Bool {
        guard at > start else { return true }
        let before = base[at - 1]
        let isAlnum = (before >= 0x30 && before <= 0x39) || (before >= 0x61 && before <= 0x7A) || before >= 0x80
        return !isAlnum
    }

    /// Folded UTF-8 bytes: ASCII lowercased in place, anything else through Foundation's case and
    /// accent folding (the same as ``FileNameMatcher``).
    static func fold(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] |= 0x20 }
            return bytes
        }
        return Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).precomposedStringWithCanonicalMapping.utf8)
    }

    /// The buffers a walk fills.
    private struct Builder {
        var paths: [String] = []
        var directories: [Bool] = []
        var folded: [UInt8] = []
        var starts: [UInt32] = []
        var count: Int { paths.count }

        mutating func add(relative: String, name: String, isDirectory: Bool) {
            paths.append(relative)
            directories.append(isDirectory)
            starts.append(UInt32(folded.count))
            // File system names come decomposed (HFS+ NFD); compose before folding.
            folded.append(contentsOf: FolderNameIndex.fold(name.precomposedStringWithCanonicalMapping))
            folded.append(0)
        }
    }
}
