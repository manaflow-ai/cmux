import Foundation
import zlib

/// Reads an allowlisted diff-viewer asset in chunks suitable for a URL scheme task.
/// WebKit does not honor Content-Encoding for app-owned custom schemes, so `.deflate`
/// assets must be inflated before they cross the scheme-handler boundary.
actor DiffViewerAssetReader {
    private static let maxInflatedSize = 32 * 1024 * 1024

    private let fileURL: URL
    private var decodedData: Data?
    private var decodedOffset = 0
    private var fileHandle: FileHandle?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func read(upToCount count: Int) throws -> Data {
        try Task.checkCancellation()
        try openIfNeeded()

        if let decodedData {
            guard decodedOffset < decodedData.count else { return Data() }
            let end = min(decodedOffset + count, decodedData.count)
            defer { decodedOffset = end }
            return decodedData.subdata(in: decodedOffset..<end)
        }
        return try fileHandle?.read(upToCount: count) ?? Data()
    }

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit {
        try? fileHandle?.close()
    }

    private func openIfNeeded() throws {
        guard decodedData == nil, fileHandle == nil else { return }
        if fileURL.lastPathComponent.hasSuffix(".deflate") {
            let compressed = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            decodedData = try Self.inflateZlib(compressed)
        } else {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
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
