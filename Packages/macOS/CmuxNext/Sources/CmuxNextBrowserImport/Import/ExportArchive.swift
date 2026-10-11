public import Foundation
import Compression

/// The parts cmux imports from a browser's export archive (Safari: File >
/// Export Browsing Data to File…, a zip of Bookmarks.html, History.json,
/// Passwords.csv and more), matched by file name in any folder. Nothing else
/// in the archive is inflated: its credit cards and extensions are never
/// read. The archive is read into `SecretBytes` (its passwords are only
/// deflated there), and each Passwords.csv inflates straight into its own.
public struct ExportArchive: Sendable {
    public var bookmarksHTML: [String] = []
    public var historyJSON: [Data] = []
    public var passwordCSVs: [SecretBytes] = []

    public var isEmpty: Bool { bookmarksHTML.isEmpty && historyJSON.isEmpty && passwordCSVs.isEmpty }

    init() {}

    /// Reads `file` (call off the main actor).
    public init(contentsOf file: URL) throws {
        let bytes: SecretBytes
        do { bytes = try PasswordCSVImporter.read(file, limit: Self.maximumSize) } catch { throw Failure.unreadable }
        self = try bytes.withUnsafeBytes { try Self.archive(in: $0) }
    }

    public enum Failure: Error, Equatable, Sendable {
        case unreadable
        case notAnArchive
    }

    /// Larger than any browser's export.
    static let maximumSize = 512 << 20
    /// One part, inflated.
    static let maximumPart = 64 << 20

    private enum Part {
        case bookmarks, history, passwords

        /// By file name; macOS resource forks (`__MACOSX/`, `._name`) are not parts.
        init?(_ path: String) {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            guard !path.hasPrefix("__MACOSX/"), !name.hasPrefix("._") else { return nil }
            switch name.lowercased() {
            case "bookmarks.html": self = .bookmarks
            case "history.json", "browserhistory.json": self = .history
            case "passwords.csv": self = .passwords
            default: return nil
            }
        }
    }

    /// Whether `head` (a file's first bytes) starts a zip archive.
    public static func isArchive(_ head: Data) -> Bool {
        head.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    static func archive(in zip: UnsafeRawBufferPointer) throws -> ExportArchive {
        guard let end = endOfCentralDirectory(zip) else { throw Failure.notAnArchive }
        let count = Int(zip.u16(end + 10)), start = Int(zip.u32(end + 16))
        var archive = ExportArchive()
        var offset = start, inflated = 0
        for _ in 0..<count {
            guard offset >= 0, offset + 46 <= zip.count, zip.u32(offset) == 0x0201_4B50 else { throw Failure.notAnArchive }
            let flags = zip.u16(offset + 8), method = zip.u16(offset + 10)
            let compressed = Int(zip.u32(offset + 20)), size = Int(zip.u32(offset + 24))
            let nameLength = Int(zip.u16(offset + 28)), local = Int(zip.u32(offset + 42))
            guard offset + 46 + nameLength <= zip.count else { throw Failure.notAnArchive }
            let name = String(decoding: UnsafeRawBufferPointer(rebasing: zip[(offset + 46)..<(offset + 46 + nameLength)]), as: UTF8.self)
            offset += 46 + nameLength + Int(zip.u16(offset + 30)) + Int(zip.u16(offset + 32))
            // Encrypted entries and oversized (or zip64) parts are skipped, never guessed at;
            // so is anything past the archive's size in all, and a second passwords file.
            guard let part = Part(name), flags & 1 == 0, size <= maximumPart, inflated + size <= maximumSize,
                  part != .passwords || archive.passwordCSVs.isEmpty,
                  let source = payload(zip, local: local, compressed: compressed) else { continue }
            inflated += size
            switch part {
            case .passwords:
                var ok = false
                let secret = SecretBytes(capacity: size) { out in
                    let written = inflate(source, method: method, size: size, into: out)
                    ok = written != nil
                    return written ?? 0
                }
                if ok { archive.passwordCSVs.append(secret) }
            case .bookmarks, .history:
                var data = Data(count: size)
                let written = data.withUnsafeMutableBytes { inflate(source, method: method, size: size, into: $0) }
                guard written != nil else { continue }
                if part == .bookmarks {
                    archive.bookmarksHTML.append(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                } else {
                    archive.historyJSON.append(data)
                }
            }
        }
        return archive
    }

    /// The end-of-central-directory record, searched back from the end (it may carry a comment).
    private static func endOfCentralDirectory(_ zip: UnsafeRawBufferPointer) -> Int? {
        guard zip.count >= 22 else { return nil }
        let last = zip.count - 22
        for offset in stride(from: last, through: max(0, last - 0xFFFF), by: -1) where zip.u32(offset) == 0x0605_4B50 {
            return offset
        }
        return nil
    }

    /// An entry's stored bytes, after its local header.
    private static func payload(_ zip: UnsafeRawBufferPointer, local: Int, compressed: Int) -> UnsafeRawBufferPointer? {
        guard local >= 0, local + 30 <= zip.count, zip.u32(local) == 0x0403_4B50 else { return nil }
        let start = local + 30 + Int(zip.u16(local + 26)) + Int(zip.u16(local + 28))
        guard start <= zip.count, compressed <= zip.count - start else { return nil }
        return UnsafeRawBufferPointer(rebasing: zip[start..<(start + compressed)])
    }

    /// Stored or deflated bytes into `out`; how many, or nil when they do not come to `size`.
    private static func inflate(_ source: UnsafeRawBufferPointer, method: UInt16, size: Int,
                                into out: UnsafeMutableRawBufferPointer) -> Int? {
        guard size > 0 else { return 0 }
        guard size <= out.count, let destination = out.baseAddress else { return nil }
        switch method {
        case 0:
            guard source.count == size, let from = source.baseAddress else { return nil }
            destination.copyMemory(from: from, byteCount: size)
            return size
        case 8:
            guard let from = source.baseAddress else { return nil }
            // COMPRESSION_ZLIB is raw DEFLATE, what a zip entry holds.
            let written = compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), size,
                                                    from.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB)
            return written == size ? size : nil
        default:
            return nil
        }
    }
}

private extension UnsafeRawBufferPointer {
    /// Little-endian fields; 0 past the end (the callers bound their offsets first).
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
