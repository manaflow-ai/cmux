public import Foundation

/// Lists a folder's files for a grid, off the main actor.
///
/// One `contentsOfDirectory` read per folder with the size and date keys
/// prefetched, so a folder of thousands of screenshots lists in one pass with
/// no per-file `stat` round trip. Subfolders are entered as the
/// ``FileGridScanRule`` says.
public nonisolated struct DirectoryScanner: Sendable {
    /// The result of one scan.
    public struct Result: Sendable, Equatable {
        /// The files the rule lists, unsorted.
        public var items: [FileGridItem]
        /// False when the folder itself could not be read (missing, or no permission).
        public var readable: Bool
    }

    /// Makes a scanner.
    public init() {}

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]

    /// Lists `folder` under `rule`, on a background executor.
    ///
    /// - Parameters:
    ///   - folder: the folder to list.
    ///   - sourceID: stamped on every item.
    ///   - rule: which files and subfolders to list.
    /// - Returns: the items and whether the folder could be read.
    @concurrent
    public func scan(_ folder: URL, sourceID: String, rule: FileGridScanRule) async -> Result {
        scanNow(folder, sourceID: sourceID, rule: rule)
    }

    /// Lists `folder` on the calling thread (tests, and ``scan(_:sourceID:rule:)``).
    ///
    /// - Parameters:
    ///   - folder: the folder to list.
    ///   - sourceID: stamped on every item.
    ///   - rule: which files and subfolders to list.
    /// - Returns: the items and whether the folder could be read.
    public func scanNow(_ folder: URL, sourceID: String, rule: FileGridScanRule) -> Result {
        let manager = FileManager()
        var items: [FileGridItem] = []
        guard let readable = list(folder, depth: rule.depth, sourceID: sourceID, rule: rule, manager: manager, into: &items) else {
            return Result(items: [], readable: false)
        }
        return Result(items: items, readable: readable)
    }

    /// The item for one path the watcher reported, nil when the file is gone or the rule leaves it out.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - sourceID: stamped on the item.
    ///   - rule: which files are listed.
    @concurrent
    public func item(at url: URL, sourceID: String, rule: FileGridScanRule) async -> FileGridItem? {
        itemNow(at: url, sourceID: sourceID, rule: rule)
    }

    /// ``item(at:sourceID:rule:)`` on the calling thread.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - sourceID: stamped on the item.
    ///   - rule: which files are listed.
    public func itemNow(at url: URL, sourceID: String, rule: FileGridScanRule) -> FileGridItem? {
        // A URL caches its resource values: a fresh one reads the disk now (a deleted file is nil).
        var url = URL(fileURLWithPath: url.path)
        url.removeAllCachedResourceValues()
        guard let kind = rule.kind(ofFileNamed: url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        return Self.item(url, kind: kind, values: values, sourceID: sourceID)
    }

    /// Appends the folder's listed files; nil when the folder could not be read.
    private func list(_ folder: URL, depth: Int, sourceID: String, rule: FileGridScanRule, manager: FileManager,
                      into items: inout [FileGridItem]) -> Bool? {
        guard let urls = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { continue }
            let name = url.lastPathComponent
            // A bundle (Cap's .cap) is a folder on disk; it is entered like one.
            if values.isDirectory == true {
                if depth > 0, rule.entersFolder(named: name) {
                    _ = list(url, depth: depth - 1, sourceID: sourceID, rule: rule, manager: manager, into: &items)
                }
                continue
            }
            guard values.isRegularFile == true, let kind = rule.kind(ofFileNamed: name) else { continue }
            items.append(Self.item(url, kind: kind, values: values, sourceID: sourceID))
        }
        return true
    }

    private static func item(_ url: URL, kind: FileGridMediaKind, values: URLResourceValues, sourceID: String) -> FileGridItem {
        FileGridItem(url: url, kind: kind, size: Int64(values.fileSize ?? 0),
                     modified: values.contentModificationDate ?? .distantPast, sourceID: sourceID)
    }
}
