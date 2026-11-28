import CCmuxScreenshots
public import CmuxNextFileGrid
public import CmuxNextFiles
public import Foundation

/// Reads a source's folders through CmuxNextFiles' ``DirectoryListing`` (one
/// `getattrlistbulk` pass per folder, off the main actor): the files its rule
/// lists, and every folder it entered, which the model then watches. Which folders it enters and
/// what each entry is listed as are Rust's (cmux-screenshots `reader.rs` `Walk`); this lists the disk.
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
        let walk = RustHandle(ScreenshotsFFI.bytes(source.folder.path) { cmux_screenshots_walk_new(source.rule.pointer, $0, $1) }) {
            cmux_screenshots_walk_free($0)
        }
        var items: [FileGridItem] = []
        while let path = ScreenshotsFFI.take(cmux_screenshots_walk_next(walk.pointer)) {
            let listed = try? await lister.list(URL(fileURLWithPath: path, isDirectory: true)), entries = listed ?? []
            var kinds = [UInt32](repeating: 0, count: entries.count)
            Self.raw(entries) { raw in
                kinds.withUnsafeMutableBufferPointer { cmux_screenshots_walk_listed(walk.pointer, listed != nil, raw, raw.count, $0.baseAddress) }
            }
            items += zip(entries, kinds).compactMap { entry, raw in
                ScreenshotsFFI.kind(raw).map { Self.item(entry, kind: $0, in: source) }
            }
        }
        let found = ScreenshotsFFI.object(cmux_screenshots_walk_result(walk.pointer))
        return Result(items: items, folders: found["folders"] as? [String] ?? [], readable: found["readable"] as? Bool ?? false)
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
        let index = Self.raw(entries) { cmux_screenshots_newest_picture($0, $0.count) }
        guard index >= 0 else { return nil }
        let newest = entries[Int(index)]
        return newest.parent.appendingPathComponent(newest.name)
    }

    /// The newest picture in the macOS screenshot folder (`com.apple.screencapture location`, else
    /// Desktop): Paste Last Screenshot's file.
    @concurrent
    public func newestSystemScreenshot() async -> URL? {
        await newestPicture(in: ScreenshotSourceDetector(environment: SystemScreenshotEnvironment()).systemFolder())
    }

    /// The item an entry is listed as, nil when the rule leaves it out.
    static func item(_ entry: FileEntry, in source: ScreenshotSource) -> FileGridItem? {
        source.rule.kind(entryKind: ScreenshotsFFI.raw(entry.kind), hidden: entry.isHidden, name: entry.name).map {
            item(entry, kind: $0, in: source)
        }
    }

    private static func item(_ entry: FileEntry, kind: FileGridMediaKind, in source: ScreenshotSource) -> FileGridItem {
        FileGridItem(url: entry.parent.appendingPathComponent(entry.name), kind: kind, size: entry.size,
                     modified: entry.modified, sourceID: source.id)
    }

    /// Runs `body` with the entries as the C ABI's, their names' bytes alive for the call.
    private static func raw<R>(_ entries: [FileEntry], _ body: ([CmuxScreenshotsEntry]) -> R) -> R {
        ScreenshotsFFI.strings(entries.map(\.name)) { names in
            body(zip(entries, names).map { entry, name in
                CmuxScreenshotsEntry(kind: ScreenshotsFFI.raw(entry.kind), hidden: entry.isHidden, name: name.bytes,
                                     name_len: name.count, system_kind: ScreenshotsFFI.systemKind(ofFileNamed: entry.name),
                                     modified: entry.modified.timeIntervalSince1970)
            })
        }
    }
}
