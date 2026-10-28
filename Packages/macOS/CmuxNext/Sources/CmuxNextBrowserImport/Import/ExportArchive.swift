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
        self = try Self.archive(in: bytes)
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

    /// The parts of the zip held in `file`, read in place.
    static func archive(in file: SecretBytes) throws(Failure) -> ExportArchive {
        try file.withUnsafeBytes { (raw) throws(Failure) in
            // SAFETY: the view lives only for this closure, while `file` lends its bytes; the archive
            // holds parts copied (inflated) out of it.
            try archive(in: unsafe ByteView(raw))
        }
    }

    static func archive(in zip: ByteView) throws(Failure) -> ExportArchive {
        guard let end = endOfCentralDirectory(zip) else { throw Failure.notAnArchive }
        let count = zip.littleEndian16(end + 10).widened, start = zip.littleEndian32(end + 16).widened
        var archive = ExportArchive()
        var offset = start, inflated = 0
        for _ in 0..<count {
            guard offset >= 0, offset + 46 <= zip.count, zip.littleEndian32(offset) == 0x0201_4B50 else { throw .notAnArchive }
            let flags = zip.littleEndian16(offset + 8), method = zip.littleEndian16(offset + 10)
            let compressed = zip.littleEndian32(offset + 20).widened, size = zip.littleEndian32(offset + 24).widened
            let nameLength = zip.littleEndian16(offset + 28).widened, local = zip.littleEndian32(offset + 42).widened
            guard let name = zip.view((offset + 46)..<(offset + 46 + nameLength))?.text else { throw .notAnArchive }
            offset += 46 + nameLength + zip.littleEndian16(offset + 30).widened + zip.littleEndian16(offset + 32).widened
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
                    // SAFETY: `out` is the buffer SecretBytes lends for this closure, max(size, 1) bytes;
                    // inflate writes at most `size` of them.
                    let written = unsafe inflate(source, method: method, size: size, into: out)
                    ok = written != nil
                    return written ?? 0
                }
                if ok { archive.passwordCSVs.append(secret) }
            case .bookmarks, .history:
                var data = Data(count: size)
                let written = data.withUnsafeMutableBytes { out in
                    // SAFETY: `out` is the Data's `size` bytes, lent for this closure; inflate writes at most `size`.
                    unsafe inflate(source, method: method, size: size, into: out)
                }
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
    private static func endOfCentralDirectory(_ zip: ByteView) -> Int? {
        guard zip.count >= 22 else { return nil }
        let last = zip.count - 22
        for offset in stride(from: last, through: max(0, last - 0xFFFF), by: -1) where zip.littleEndian32(offset) == 0x0605_4B50 {
            return offset
        }
        return nil
    }

    /// An entry's stored bytes, after its local header.
    private static func payload(_ zip: ByteView, local: Int, compressed: Int) -> ByteView? {
        guard local >= 0, local + 30 <= zip.count, zip.littleEndian32(local) == 0x0403_4B50 else { return nil }
        let start = local + 30 + zip.littleEndian16(local + 26).widened + zip.littleEndian16(local + 28).widened
        guard start <= zip.count, compressed <= zip.count - start else { return nil }
        return zip.view(start..<(start + compressed))
    }

    /// Stored or deflated bytes into `out`; how many, or nil when they do not come to `size`.
    /// `out` must hold at least `size` writable bytes for the call (checked).
    @unsafe private static func inflate(_ source: ByteView, method: UInt16, size: Int,
                                        into out: UnsafeMutableRawBufferPointer) -> Int? {
        guard size > 0 else { return 0 }
        // SAFETY: reads the count and start of the buffer the caller lends for this call.
        guard unsafe size <= out.count, let destination = unsafe out.baseAddress else { return nil }
        return source.withUnsafeBytes { input -> Int? in
            switch method {
            case 0:
                // SAFETY: reads the count and start of the entry's bytes, lent for this closure.
                guard unsafe input.count == size, let from = unsafe input.baseAddress else { return nil }
                // SAFETY: copies `size` bytes: the stored entry holds exactly that many (checked) and
                // `destination` at least that many (checked above); the ranges are different buffers.
                unsafe destination.copyMemory(from: from, byteCount: size)
                return size
            case 8:
                // SAFETY: reads the start of the entry's bytes, lent for this closure.
                guard let from = unsafe input.baseAddress else { return nil }
                // COMPRESSION_ZLIB is raw DEFLATE, what a zip entry holds.
                // SAFETY: the decoder reads at most input.count bytes from `from` and writes at most `size`
                // to `destination`, the counts passed, both inside their lent buffers (checked above).
                let written = unsafe compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), size,
                                                               from.assumingMemoryBound(to: UInt8.self), input.count, nil,
                                                               COMPRESSION_ZLIB)
                return written == size ? size : nil
            default:
                return nil
            }
        }
    }
}
