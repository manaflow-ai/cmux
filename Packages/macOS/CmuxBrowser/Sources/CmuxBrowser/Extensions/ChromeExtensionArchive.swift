public import Foundation
import Compression

/// A minimal, budgeted ZIP extractor for extension payloads.
///
/// It reads the central directory, refuses anything it does not need
/// (encryption, zip64, symbolic links, special files, duplicate or unsafe
/// names), and inflates each file while counting the bytes it writes, so an
/// archive that understates its sizes is stopped at the budget instead of
/// after the disk fills. Only the `stored` and `deflate` methods are
/// supported, which is what CRX payloads use.
enum ChromeExtensionArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    /// Parses the central directory.
    static func entries(in zip: Data) throws -> [Entry] {
        // Read in place; the payload is never copied into an array.
        let base = zip.startIndex
        let size = zip.count
        func byte(_ at: Int) -> Int { Int(zip[base + at]) }
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= size else { throw ChromeExtensionPackage.Failure.unpack("truncated archive") }
            return byte(at) | byte(at + 1) << 8
        }
        func u32(_ at: Int) throws -> Int {
            guard at >= 0, at + 4 <= size else { throw ChromeExtensionPackage.Failure.unpack("truncated archive") }
            return byte(at) | byte(at + 1) << 8 | byte(at + 2) << 16 | byte(at + 3) << 24
        }

        // End of central directory: within the last 22 + 65535 bytes.
        let lowest = max(0, size - 22 - 65_535)
        var eocd = -1
        var index = size - 22
        while index >= lowest {
            if try u32(index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ChromeExtensionPackage.Failure.unpack("not a zip archive") }
        let count = try u16(eocd + 10)
        let directorySize = try u32(eocd + 12)
        let directoryOffset = try u32(eocd + 16)
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ChromeExtensionPackage.Failure.unpack("zip64 archives are not supported")
        }
        guard count <= ChromeExtensionPackage.maximumEntryCount,
              directoryOffset + directorySize <= eocd else {
            throw ChromeExtensionPackage.Failure.unpack("malformed archive directory")
        }

        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            guard try u32(cursor) == 0x0201_4b50 else { throw ChromeExtensionPackage.Failure.unpack("malformed archive directory") }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20)
            let uncompressed = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            let externalAttributes = try u32(cursor + 38)
            let localOffset = try u32(cursor + 42)
            guard cursor + 46 + nameLength <= size,
                  let name = String(data: zip[(base + cursor + 46)..<(base + cursor + 46 + nameLength)], encoding: .utf8) else {
                throw ChromeExtensionPackage.Failure.unpack("unreadable archive name")
            }
            guard flags & 0x1 == 0 else { throw ChromeExtensionPackage.Failure.unpack("encrypted archives are not supported") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ChromeExtensionPackage.Failure.unpack("zip64 archives are not supported")
            }
            let unixType = (externalAttributes >> 16) & 0xF000
            let isDirectory = name.hasSuffix("/")
            guard unixType == 0 || unixType == 0x8000 || (isDirectory && unixType == 0x4000) else {
                throw ChromeExtensionPackage.Failure.unpack("links and special files are not allowed")
            }
            guard method == 0 || method == 8 else { throw ChromeExtensionPackage.Failure.unpack("unsupported compression") }
            entries.append(Entry(
                name: name,
                method: UInt16(method),
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                isDirectory: isDirectory
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Extracts `zip` into `output`, which must not exist yet.
    static func extract(_ zip: Data, into output: URL, byteBudget: Int, fileManager: FileManager) throws {
        let entries = try entries(in: zip)
        try ChromeExtensionPackage.validateArchiveEntryNames(entries.map(\.name))
        guard Set(entries.map(\.name)).count == entries.count else {
            throw ChromeExtensionPackage.Failure.unpack("duplicate archive names")
        }
        let declared = entries.reduce(0) { $0 + $1.uncompressedSize }
        guard declared <= byteBudget else { throw ChromeExtensionPackage.Failure.unpack("the extension is too large") }

        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        var written = 0
        for entry in entries {
            let target = output.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try payload(of: entry, in: zip)
            guard fileManager.createFile(atPath: target.path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: target.path) else {
                throw ChromeExtensionPackage.Failure.unpack("cannot write \(entry.name)")
            }
            defer { try? handle.close() }
            // Each file may not exceed its declared size, and all files
            // together may not exceed the budget; both are enforced as bytes
            // are produced.
            let fileLimit = entry.uncompressedSize
            var fileWritten = 0
            let sink: (Data) throws -> Void = { chunk in
                fileWritten += chunk.count
                written += chunk.count
                guard fileWritten <= fileLimit, written <= byteBudget else {
                    throw ChromeExtensionPackage.Failure.unpack("the extension is larger than it declares")
                }
                try handle.write(contentsOf: chunk)
            }
            switch entry.method {
            case 0:
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ChromeExtensionPackage.Failure.unpack("malformed stored entry")
                }
                try sink(data)
            default:
                try inflate(data, limit: fileLimit, into: sink)
            }
            guard fileWritten == fileLimit else { throw ChromeExtensionPackage.Failure.unpack("\(entry.name) is truncated") }
        }
    }

    private static func payload(of entry: Entry, in zip: Data) throws -> Data {
        let base = zip.startIndex
        let header = base + entry.localHeaderOffset
        guard entry.localHeaderOffset + 30 <= zip.count,
              zip[header] == 0x50, zip[header + 1] == 0x4b, zip[header + 2] == 0x03, zip[header + 3] == 0x04 else {
            throw ChromeExtensionPackage.Failure.unpack("malformed local header")
        }
        let nameLength = Int(zip[header + 26]) | Int(zip[header + 27]) << 8
        let extraLength = Int(zip[header + 28]) | Int(zip[header + 29]) << 8
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= zip.count else { throw ChromeExtensionPackage.Failure.unpack("truncated entry") }
        return zip[(base + start)..<(base + start + entry.compressedSize)]
    }

    /// Raw DEFLATE, streamed in chunks; stops as soon as output passes `limit`.
    private static func inflate(_ input: Data, limit: Int, into sink: (Data) throws -> Void) throws {
        let chunkSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ChromeExtensionPackage.Failure.unpack("cannot start decompression")
        }
        defer { compression_stream_destroy(&stream) }
        var produced = 0
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = source
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let count = chunkSize - stream.dst_size
                if count > 0 {
                    produced += count
                    guard produced <= limit else { throw ChromeExtensionPackage.Failure.unpack("the extension is larger than it declares") }
                    try sink(Data(bytes: destination, count: count))
                }
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK:
                    // No output and no input left means the stream is cut
                    // short; stop instead of spinning.
                    guard count > 0 || stream.src_size > 0 else {
                        throw ChromeExtensionPackage.Failure.unpack("corrupt compressed data")
                    }
                    continue
                default: throw ChromeExtensionPackage.Failure.unpack("corrupt compressed data")
                }
            }
        }
    }
}
