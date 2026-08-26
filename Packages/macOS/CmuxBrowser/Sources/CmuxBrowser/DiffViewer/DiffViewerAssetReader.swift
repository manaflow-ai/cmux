import Darwin
public import Foundation
import zlib

/// Reads allowlisted diff-viewer assets in chunks suitable for a URL scheme task.
///
/// WebKit does not honor `Content-Encoding` for app-owned custom schemes, so
/// `.deflate` assets are inflated before they cross the scheme-handler boundary.
/// One actor admits exactly one stream at a time, bounding aggregate decoded data
/// to one 32 MiB buffer. At most 64 additional streams wait by default, which
/// makes the queue's linear cancellation/removal operations strictly bounded.
public actor DiffViewerAssetReader {
    private static let maximumCompressedSize = 32 * 1024 * 1024
    private static let maximumInflatedSize = 32 * 1024 * 1024

    private let maximumWaitingStreams: Int
    private var activeStreamID: UUID?
    private var activeFileURL: URL?
    private var decodedData: Data?
    private var decodedOffset = 0
    private var fileHandle: FileHandle?
    private var waitingStreams: [WaitingStream] = []
    private let waitingStreamDidEnqueue: (@Sendable (UUID) -> Void)?

    /// Creates a single-flight reader with a bounded FIFO waiting queue.
    ///
    /// - Parameter maximumWaitingStreams: Maximum queued streams in addition to
    ///   the active stream. `0` rejects every concurrent request immediately.
    public init(maximumWaitingStreams: Int = 64) {
        self.maximumWaitingStreams = max(0, maximumWaitingStreams)
        waitingStreamDidEnqueue = nil
    }

    /// Creates a reader that reports when a concurrent stream joins the wait queue.
    init(
        maximumWaitingStreams: Int,
        waitingStreamDidEnqueue: @escaping @Sendable (UUID) -> Void
    ) {
        self.maximumWaitingStreams = max(0, maximumWaitingStreams)
        self.waitingStreamDidEnqueue = waitingStreamDidEnqueue
    }

    /// Reads the next chunk for a stream, waiting for bounded FIFO admission when necessary.
    ///
    /// - Parameters:
    ///   - streamID: Stable identity for one WebKit request generation.
    ///   - fileURL: Validated local asset URL.
    ///   - count: Maximum bytes to return; must be positive.
    /// - Returns: The next chunk, or empty data at end of file.
    /// - Throws: A cancellation, capacity, file I/O, or bounded-inflation error.
    public func read(streamID: UUID, fileURL: URL, upToCount count: Int) async throws -> Data {
        guard count > 0 else { throw CocoaError(.fileReadUnknown) }
        if activeStreamID != streamID {
            try await waitForTurn(streamID: streamID, fileURL: fileURL)
        }
        try Task.checkCancellation()
        guard activeStreamID == streamID else {
            throw CocoaError(.fileReadUnknown)
        }
        try openIfNeeded()

        if let decodedData {
            guard decodedOffset < decodedData.count else { return Data() }
            let end = min(decodedOffset + count, decodedData.count)
            defer { decodedOffset = end }
            return decodedData.subdata(in: decodedOffset..<end)
        }
        return try fileHandle?.read(upToCount: count) ?? Data()
    }

    /// Closes an active stream or cancels a queued stream, then admits the next waiter.
    ///
    /// - Parameter streamID: Stable identity of the active or queued stream to close.
    public func close(streamID: UUID) {
        guard activeStreamID == streamID else {
            cancelWaitingStream(streamID: streamID)
            return
        }
        try? fileHandle?.close()
        fileHandle = nil
        decodedData = nil
        decodedOffset = 0
        activeStreamID = nil
        activeFileURL = nil
        admitNextStream()
    }

    deinit {
        try? fileHandle?.close()
        for waitingStream in waitingStreams {
            waitingStream.continuation.resume(throwing: CancellationError())
        }
    }

    private func waitForTurn(streamID: UUID, fileURL: URL) async throws {
        try Task.checkCancellation()
        if activeStreamID == nil {
            activateStream(id: streamID, fileURL: fileURL)
            return
        }
        guard waitingStreams.count < maximumWaitingStreams else {
            throw DiffViewerAssetReaderError.capacityExceeded
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waitingStreams.append(WaitingStream(
                    id: streamID,
                    fileURL: fileURL,
                    continuation: continuation
                ))
                waitingStreamDidEnqueue?(streamID)
            }
        } onCancel: {
            Task {
                await self.cancelWaitingStream(streamID: streamID)
            }
        }
    }

    private func cancelWaitingStream(streamID: UUID) {
        guard let index = waitingStreams.firstIndex(where: { $0.id == streamID }) else {
            return
        }
        let waitingStream = waitingStreams.remove(at: index)
        waitingStream.continuation.resume(throwing: CancellationError())
    }

    private func admitNextStream() {
        guard !waitingStreams.isEmpty else { return }
        let next = waitingStreams.removeFirst()
        activateStream(id: next.id, fileURL: next.fileURL)
        next.continuation.resume(returning: ())
    }

    private func activateStream(id: UUID, fileURL: URL) {
        activeStreamID = id
        activeFileURL = fileURL
    }

    private func openIfNeeded() throws {
        guard decodedData == nil, fileHandle == nil else { return }
        guard let activeFileURL else { throw CocoaError(.fileReadUnknown) }
        if activeFileURL.lastPathComponent.hasSuffix(".deflate") {
            let compressed = try Self.readCompressedAsset(at: activeFileURL)
            decodedData = try Self.inflateZlib(compressed)
        } else {
            fileHandle = try Self.openRegularFile(at: activeFileURL)
        }
    }

    private static func readCompressedAsset(at fileURL: URL) throws -> Data {
        let handle = try openRegularFile(at: fileURL)
        defer { try? handle.close() }

        var compressed = Data()
        while compressed.count <= maximumCompressedSize {
            let remaining = maximumCompressedSize + 1 - compressed.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            compressed.append(chunk)
        }
        guard compressed.count <= maximumCompressedSize else {
            throw CocoaError(.fileReadTooLarge)
        }
        return compressed
    }

    /// Opens without blocking on special files and rejects anything except a regular file.
    private static func openRegularFile(at fileURL: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let errorCode = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadCorruptFile)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func inflateZlib(_ compressed: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw CocoaError(.fileReadCorruptFile)
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                try Task.checkCancellation()
                let result = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                guard output.count <= maximumInflatedSize - produced else {
                    throw CocoaError(.fileReadTooLarge)
                }
                output.append(chunk, count: produced)

                if result == Z_STREAM_END {
                    return output
                }
                guard result == Z_OK, stream.avail_in > 0 || produced > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }

    private struct WaitingStream {
        let id: UUID
        let fileURL: URL
        let continuation: CheckedContinuation<Void, any Error>
    }
}
