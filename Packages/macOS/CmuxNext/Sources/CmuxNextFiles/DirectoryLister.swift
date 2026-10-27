public import Foundation

/// Lists one folder's children: the seam the Files model reads through.
///
/// Tests pass a fake that returns fixed entries; the app uses
/// ``DirectoryLister``.
public protocol DirectoryListing: Sendable {
    /// Every child of `folder` (hidden ones included; the model filters).
    /// - Throws: ``FileBrowserError/unreadable(_:_:)`` when the folder cannot be opened.
    func list(_ folder: URL) async throws -> [FileEntry]

    /// The current entry for one item, or nil when it no longer exists
    /// (for live updates of single paths).
    func entry(at url: URL) async -> FileEntry?
}

/// Lists folders off the main actor: name, type, dates, flags and size per item.
///
/// On macOS one `getattrlistbulk(2)` call reads up to a few thousand items
/// (DirectoryLister+Darwin.swift); elsewhere `readdir(3)` and one `fstatat(2)`
/// per item (DirectoryLister+Linux.swift). One interface, one file per
/// platform, as Chromium's base::FileEnumerator (base/files/file_enumerator.h,
/// file_enumerator_posix.cc).
///
/// Measured on 100 000 files: ~230 ms with `FileManager` plus resource keys,
/// against ~56 s for Finder's own `name of every item` (PARITY.md).
public struct DirectoryLister: DirectoryListing {
    /// Makes a lister. It holds no state.
    public init() {}

    @concurrent
    public func list(_ folder: URL) async throws -> [FileEntry] {
        try Self.listSync(folder)
    }

    @concurrent
    public func entry(at url: URL) async -> FileEntry? {
        Self.entrySync(at: url)
    }

    /// True for a folder name Finder shows as one item (by its extension's type).
    public static func isPackage(_ name: String, types: some FileTypeRegistry = SystemFileTypes()) -> Bool {
        types.isPackage(pathExtension: (name as NSString).pathExtension.lowercased())
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}
