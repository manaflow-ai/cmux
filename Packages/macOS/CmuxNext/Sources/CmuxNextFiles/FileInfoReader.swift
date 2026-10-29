public import CmuxNextWakeups
public import Foundation

/// Reads and changes what Get Info shows, on the app's files lane.
public struct FileInfoReader: Sendable {
    /// What a volume reports as free: for important use, and plain. Either may be missing.
    public typealias VolumeCapacity = @Sendable (URL) -> (important: Int64?, plain: Int64?)

    private let volumeCapacity: VolumeCapacity
    /// The app's blocking-work lanes.
    private let work: BackgroundWork

    /// Makes a reader on `work`. Tests pass `volumeCapacity` so they don't read the machine's real disk.
    public init(work: BackgroundWork, volumeCapacity: @escaping VolumeCapacity = FileInfoReader.systemVolumeCapacity) {
        self.work = work
        self.volumeCapacity = volumeCapacity
    }

    /// The volume's free space as Foundation reports it.
    public static func systemVolumeCapacity(of url: URL) -> (important: Int64?, plain: Int64?) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeAvailableCapacity.map(Int64.init))
    }

    /// Reads `url`'s Get Info record.
    /// - Throws: ``FileBrowserError/missing(_:)`` when the item is gone.
    public func info(for url: URL) async throws -> FileInfo {
        try await work.run(.userBlocking, mayBlock: .files) { try Self.readInfo(url) }
    }

    private static func readInfo(_ url: URL) throws -> FileInfo {
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
    public func folderSize(of folder: URL) async -> FolderSize {
        // A walk of a home folder takes minutes: it runs on the bulk lane, never on the serial files slot every
        // other Files call at its priority waits on, and checks the flag the caller's cancel sets.
        let stop = FileWorkStop()
        return await withTaskCancellationHandler {
            (try? await work.run(.userVisible, mayBlock: .bulkFiles) { Self.walk(folder, stop: stop) }) ?? FolderSize()
        } onCancel: {
            stop.set()
        }
    }

    private static func walk(_ folder: URL, stop: FileWorkStop) -> FolderSize {
        var total = FolderSize()
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else { return total }
        while let url = walker.nextObject() as? URL {
            if stop.isSet { break }
            total.items += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total.bytes += Int64(values.fileSize ?? 0)
            total.allocated += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The space free for new files on `url`'s volume (the status line's "X available"), or nil when
    /// unknown. Some volumes report 0 for important use, and a 0 overall reads as unknown, not a full disk.
    public func availableCapacity(of url: URL) async -> Int64? {
        let volumeCapacity = volumeCapacity
        let free = try? await work.run(.userVisible, mayBlock: .files) { () -> Int64? in
            let reported = volumeCapacity(url)
            return [reported.important, reported.plain].lazy.compactMap { $0 }.first { $0 > 0 }
        }
        return free ?? nil
    }

    /// Sets the Locked box.
    public func setLocked(_ locked: Bool, for url: URL) async throws {
        try await work.run(.userBlocking, mayBlock: .files) { try Self.set(url) { $0.isUserImmutable = locked } }
    }

    /// Sets the Hide extension box.
    public func setExtensionHidden(_ hidden: Bool, for url: URL) async throws {
        try await work.run(.userBlocking, mayBlock: .files) { try Self.set(url) { $0.hasHiddenExtension = hidden } }
    }

    private static func set(_ url: URL, _ change: (inout URLResourceValues) -> Void) throws {
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
