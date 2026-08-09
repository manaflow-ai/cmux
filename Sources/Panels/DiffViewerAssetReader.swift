import Foundation
import zlib

/// Reads an allowlisted diff-viewer asset in chunks suitable for a URL scheme task.
/// WebKit does not honor Content-Encoding for app-owned custom schemes, so `.deflate`
/// assets must be inflated before they cross the scheme-handler boundary. One shared
/// actor admits exactly one stream at a time so decoded bytes and file handles retain
/// the same aggregate bound as the former serial stream queue.
actor DiffViewerAssetReader {
    private static let maxInflatedSize = 32 * 1024 * 1024

    private var activeStreamID: UUID?
    private var activeFileURL: URL?
    private var decodedData: Data?
    private var decodedOffset = 0
    private var fileHandle: FileHandle?
    private var waitingStreams: [(
        id: UUID,
        fileURL: URL,
        continuation: CheckedContinuation<Void, Error>
    )] = []

    func read(streamID: UUID, fileURL: URL, upToCount count: Int) async throws -> Data {
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

    func close(streamID: UUID) {
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

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waitingStreams.append((streamID, fileURL, continuation))
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
            let compressed = try Data(contentsOf: activeFileURL, options: .mappedIfSafe)
            decodedData = try Self.inflateZlib(compressed)
        } else {
            fileHandle = try FileHandle(forReadingFrom: activeFileURL)
        }
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
                guard output.count <= maxInflatedSize - produced else {
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
}
