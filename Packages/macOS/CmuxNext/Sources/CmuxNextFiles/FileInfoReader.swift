public import Foundation

/// Reads and changes what Get Info shows, off the main actor.
public struct FileInfoReader: Sendable {
    /// What a volume reports as free: for important use, and plain. Either may be missing.
    public typealias VolumeCapacity = @Sendable (URL) -> (important: Int64?, plain: Int64?)

    private let volumeCapacity: VolumeCapacity

    /// Makes a reader. Tests pass `volumeCapacity` so they don't read the machine's real disk.
    public init(volumeCapacity: @escaping VolumeCapacity = FileInfoReader.systemVolumeCapacity) {
        self.volumeCapacity = volumeCapacity
    }

    /// The volume's free space as Foundation reports it.
    public static func systemVolumeCapacity(of url: URL) -> (important: Int64?, plain: Int64?) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeAvailableCapacity.map(Int64.init))
    }

    /// Reads `url`'s Get Info record.
    /// - Throws: ``FileBrowserError/missing(_:)`` when the item is gone.
    @concurrent
    public func info(for url: URL) async throws -> FileInfo {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
                                         .isUserImmutableKey, .hasHiddenExtensionKey, .isDirectoryKey,
                                         .isPackageKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw FileBrowserError.missing(url) }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileKind: FileKind
        if values.isSymbolicLink == true {
            fileKind = .symlink
        } else if values.isPackage == true {
            fileKind = .package
        } else if values.isDirectory == true {
            fileKind = .folder
        } else {
            fileKind = .file
        }
        let isFile = fileKind == .file || fileKind == .symlink
        return FileInfo(url: url, kind: values.localizedTypeDescription ?? "",
                        size: isFile ? Int64(values.fileSize ?? 0) : nil,
                        allocatedSize: isFile ? Int64(values.totalFileAllocatedSize ?? 0) : nil,
                        created: values.creationDate, modified: values.contentModificationDate,
                        lastOpened: values.contentAccessDate,
                        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                        owner: attributes[.ownerAccountName] as? String,
                        isLocked: values.isUserImmutable ?? false,
                        isExtensionHidden: values.hasHiddenExtension ?? false, fileKind: fileKind)
    }

    /// Adds up everything inside `folder` (packages and hidden items too). Stops early when cancelled.
    @concurrent
    public func folderSize(of folder: URL) async -> FolderSize {
        var total = FolderSize()
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else { return total }
        while let url = walker.nextObject() as? URL {
            if Task.isCancelled { break }
            total.items += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total.bytes += Int64(values.fileSize ?? 0)
            total.allocated += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The space free for new files on `url`'s volume (the status line's "X available"), or nil when
    /// unknown. Some volumes report 0 for important use, and a 0 overall reads as unknown, not a full disk.
    @concurrent
    public func availableCapacity(of url: URL) async -> Int64? {
        let reported = volumeCapacity(url)
        return [reported.important, reported.plain].lazy.compactMap { $0 }.first { $0 > 0 }
    }

    /// Sets the Locked box.
    @concurrent
    public func setLocked(_ locked: Bool, for url: URL) async throws {
        try set(url) { $0.isUserImmutable = locked }
    }

    /// Sets the Hide extension box.
    @concurrent
    public func setExtensionHidden(_ hidden: Bool, for url: URL) async throws {
        try set(url) { $0.hasHiddenExtension = hidden }
    }

    private func set(_ url: URL, _ change: (inout URLResourceValues) -> Void) throws {
        var values = URLResourceValues()
        change(&values)
        var target = url
        do {
            try target.setResourceValues(values)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
    }
}
