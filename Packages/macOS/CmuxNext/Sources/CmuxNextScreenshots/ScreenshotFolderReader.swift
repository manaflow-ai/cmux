public import CmuxNextFileGrid
public import CmuxNextFiles
public import Foundation

/// Reads a source's folders through CmuxNextFiles' ``DirectoryListing`` (one
/// `getattrlistbulk` pass per folder, off the main actor): the files its rule
/// lists, and every folder it entered, which the model then watches.
///
/// ```swift
/// let result = await ScreenshotFolderReader().read(source)
/// // result.items: the source's pictures and movies; result.folders: what to watch
/// ```
public nonisolated struct ScreenshotFolderReader: Sendable {
    /// What one read found.
    public struct Result: Sendable {
        /// The listed files.
        public var items: [FileGridItem]
        /// Paths of the source's folder and every subfolder the rule entered.
        public var folders: [String]
        /// False when the source's own folder could not be read.
        public var readable: Bool
    }

    private let lister: any DirectoryListing

    /// Makes a reader.
    ///
    /// - Parameter lister: lists folders (default: the disk, ``DirectoryLister``).
    public init(lister: any DirectoryListing = DirectoryLister()) {
        self.lister = lister
    }

    /// Lists `source`'s folder and the subfolders its rule enters.
    ///
    /// - Parameter source: the source.
    /// - Returns: its files and folders.
    public func read(_ source: ScreenshotSource) async -> Result {
        var result = Result(items: [], folders: [], readable: true)
        result.readable = await read(source.folder, depth: 0, source: source, into: &result)
        return result
    }

    /// The item for one changed path, or nil when it is gone or the rule leaves it out.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - source: the source it is in.
    public func item(at url: URL, in source: ScreenshotSource) async -> FileGridItem? {
        guard let entry = await lister.entry(at: url) else { return nil }
        return Self.item(entry, in: source)
    }

    /// The facts the lister gives for one path (nil when gone): the model's look at a changed name.
    ///
    /// - Parameter url: the path.
    public func entry(at url: URL) async -> FileEntry? {
        await lister.entry(at: url)
    }

    /// The newest visible picture directly in `folder` (no subfolders), or nil when it has none or
    /// cannot be read. Runs off the main actor: a Desktop holds thousands of files.
    ///
    /// - Parameter folder: The folder to read (`ScreenshotSourceDetector/systemFolder()` for macOS screenshots).
    /// - Returns: The picture with the latest modification date; the first listed wins a tie.
    @concurrent
    public func newestPicture(in folder: URL) async -> URL? {
        guard let entries = try? await lister.list(folder) else { return nil }
        let rule = ScreenshotScanRule(kinds: [.image])
        var newest: FileEntry?
        for entry in entries where entry.kind == .file && !entry.isHidden && rule.kind(ofFileNamed: entry.name) != nil {
            if newest.map({ $0.modified < entry.modified }) ?? true { newest = entry }
        }
        return newest.map { $0.parent.appendingPathComponent($0.name) }
    }

    /// The item an entry is listed as, nil when the rule leaves it out.
    static func item(_ entry: FileEntry, in source: ScreenshotSource) -> FileGridItem? {
        guard entry.kind == .file, !entry.isHidden, let kind = source.rule.kind(ofFileNamed: entry.name) else { return nil }
        return FileGridItem(url: entry.parent.appendingPathComponent(entry.name), kind: kind, size: entry.size,
                            modified: entry.modified, sourceID: source.id)
    }

    /// Whether a listed entry is a folder the rule enters at this depth (a bundle such as Cap's `.cap` too).
    static func enters(_ entry: FileEntry, depth: Int, rule: ScreenshotScanRule) -> Bool {
        (entry.kind == .folder || entry.kind == .package) && !entry.isHidden && depth < rule.depth
            && rule.entersFolder(named: entry.name)
    }

    /// Lists one folder into `result`; false when it could not be read.
    private func read(_ folder: URL, depth: Int, source: ScreenshotSource, into result: inout Result) async -> Bool {
        guard let entries = try? await lister.list(folder) else { return false }
        result.folders.append(folder.path)
        for entry in entries {
            if Self.enters(entry, depth: depth, rule: source.rule) {
                _ = await read(folder.appendingPathComponent(entry.name, isDirectory: true), depth: depth + 1, source: source, into: &result)
            } else if let item = Self.item(entry, in: source) {
                result.items.append(item)
            }
        }
        return true
    }
}
