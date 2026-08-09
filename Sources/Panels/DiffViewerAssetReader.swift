import Foundation
import zlib

/// Reads an allowlisted diff-viewer asset in chunks suitable for a URL scheme task.
/// WebKit does not honor Content-Encoding for app-owned custom schemes, so `.deflate`
/// assets must be inflated before they cross the scheme-handler boundary. One shared
/// actor owns every open stream so reads and full-asset inflation stay globally bounded.
actor DiffViewerAssetReader {
    private static let maxInflatedSize = 32 * 1024 * 1024

    private final class Stream {
        let fileURL: URL
        var decodedData: Data?
        var decodedOffset = 0
        var fileHandle: FileHandle?

        init(fileURL: URL) {
            self.fileURL = fileURL
        }
    }

    private var streams: [UUID: Stream] = [:]

    /// This method deliberately contains no suspension point. Actor isolation
    /// therefore limits file reads and inflation to one stream at a time, matching
    /// the old serial stream queue without letting that worker touch WebKit tasks.
    func read(streamID: UUID, fileURL: URL, upToCount count: Int) throws -> Data {
        try Task.checkCancellation()
        let stream: Stream
        if let existing = streams[streamID] {
            stream = existing
        } else {
            stream = Stream(fileURL: fileURL)
            streams[streamID] = stream
        }
        try openIfNeeded(stream)

        if let decodedData = stream.decodedData {
            guard stream.decodedOffset < decodedData.count else { return Data() }
            let end = min(stream.decodedOffset + count, decodedData.count)
            defer { stream.decodedOffset = end }
            return decodedData.subdata(in: stream.decodedOffset..<end)
        }
        return try stream.fileHandle?.read(upToCount: count) ?? Data()
    }

    func close(streamID: UUID) {
        guard let stream = streams.removeValue(forKey: streamID) else { return }
        try? stream.fileHandle?.close()
        stream.fileHandle = nil
    }

    deinit {
        for stream in streams.values {
            try? stream.fileHandle?.close()
        }
    }

    private func openIfNeeded(_ stream: Stream) throws {
        guard stream.decodedData == nil, stream.fileHandle == nil else { return }
        if stream.fileURL.lastPathComponent.hasSuffix(".deflate") {
            let compressed = try Data(contentsOf: stream.fileURL, options: .mappedIfSafe)
            stream.decodedData = try Self.inflateZlib(compressed)
        } else {
            stream.fileHandle = try FileHandle(forReadingFrom: stream.fileURL)
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
