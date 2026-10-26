import CmuxNextCompat
public import Foundation

/// A file the page streams into a chat in chunks (``AgentPaneUploadStageRequest``), staged on this
/// Mac's disk off the main thread: each chunk's base64 is decoded and appended on this actor,
/// through the one handle the upload keeps open, so the main thread only looks the upload up. A
/// video's hundreds of chunks were decoded and written on the main thread, and the composer froze
/// (Leo, 2026-10-25: "the composer should never ever freeze"). The stagers own which chat a file
/// is for and when it expires; this owns its bytes. A file has any size the disk has room for.
public actor AgentPaneUploadFile {
    /// Why a staged file could not be made or written.
    public nonisolated enum Failure: Error, Equatable {
        /// The disk lacks room for the file: its free bytes.
        case noSpace(freeBytes: Int64)
        case failed
    }

    /// The folder made for the upload, which ``discard()`` deletes, and the file in it.
    public nonisolated let folder: URL
    public nonisolated let file: URL
    public nonisolated let size: Int
    private var handle: FileHandle?
    private var received = 0

    /// What a disk keeps free after an upload, so the app and the system still write.
    public nonisolated static let diskReserve: Int64 = 256 * 1024 * 1024

    private init(folder: URL, file: URL, size: Int, handle: FileHandle) {
        self.folder = folder
        self.file = file
        self.size = size
        self.handle = handle
    }

    /// Makes `folder` (owner-only, with its parents) and an empty owner-only file `name` in it for
    /// `size` bytes, when the disk that holds it (`freeBytes`) has room for them and
    /// ``diskReserve``. Runs off the main thread.
    @concurrent public static func make(folder: URL, name: String, size: Int,
                                        freeBytes: @Sendable (URL) -> Int64? = AgentPaneUploadFile.freeBytes) async throws(Failure) -> AgentPaneUploadFile {
        if let free = freeBytes(folder), Int64(size) > free - diskReserve { throw .noSpace(freeBytes: free) }
        let manager = FileManager.checked, file = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            return AgentPaneUploadFile(folder: folder, file: file, size: size, handle: try FileHandle(forWritingTo: file))
        } catch {
            try? manager.removeItem(at: folder)
            throw .failed
        }
    }

    /// Decodes chunk `base64` and appends it at `offset`, which must be where the file ends, never
    /// past `size`; answers the new end.
    public func append(offset: Int, base64: String) throws(Failure) -> Int {
        guard let handle, offset == received, let data = Data(base64Encoded: base64), !data.isEmpty,
              data.count <= AgentPaneUploadStageRequest.maximumChunkBytes, offset + data.count <= size else { throw .failed }
        do {
            try handle.blockingWrite(contentsOf: data)
        } catch {
            throw Self.isDiskFull(error) ? .noSpace(freeBytes: Self.freeBytes(folder) ?? 0) : .failed
        }
        received += data.count
        return received
    }

    /// Closes the file once it holds all its bytes; answers it. The caller sends or moves it, then
    /// ``discard()``s what is left.
    public func finish() throws(Failure) -> URL {
        guard let handle, received == size else { throw .failed }
        self.handle = nil
        do { try handle.close() } catch { throw .failed }
        return file
    }

    /// ``finish()``, then moves the file to `destination` (its folder made owner-only, with its
    /// parents) and deletes the staging folder; answers the destination. A failure deletes the file.
    public func finish(movingTo destination: URL) throws(Failure) -> URL {
        let file: URL
        do throws(Failure) { file = try finish() } catch {
            discard()
            throw error
        }
        let manager = FileManager.checked
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.moveItem(at: file, to: destination)
        } catch {
            discard()
            throw .failed
        }
        try? manager.removeItem(at: folder)
        return destination
    }

    /// Closes the file and deletes its folder: a cancel, a failure or an expiry.
    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.checked.removeItem(at: folder)
    }

    /// The bytes free for a file the person saves on the disk that holds `url`, read at its nearest
    /// existing folder; nil when the system does not say (any size is then tried).
    public nonisolated static func freeBytes(_ url: URL) -> Int64? {
        var folder = url
        while !FileManager.checked.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let values = try? folder.blockingResourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    private nonisolated static func isDiskFull(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT)))
    }
}
