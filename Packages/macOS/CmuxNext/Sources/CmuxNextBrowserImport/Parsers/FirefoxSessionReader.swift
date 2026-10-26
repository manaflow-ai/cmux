public import Foundation
import Compression

/// Reads the open tabs of Firefox's session store. The file is "mozLz4":
/// the magic `mozLz40\0`, a little-endian uint32 decompressed size, then one
/// raw LZ4 block holding JSON (`windows[].tabs[].entries[]`, `index` 1-based).
public struct FirefoxSessionReader {
    private let fileManager: FileManager

    /// Creates a reader with the filesystem used to discover Firefox sessions.
    ///
    /// - Parameter fileManager: Filesystem access for discovery.
    public init(fileManager: FileManager = FileManager()) {
        self.fileManager = fileManager
    }

    let magic = Array("mozLz40\0".utf8)
    /// Session stores above this size are not read (a sane upper bound).
    let maximumSize = 256 * 1024 * 1024

    public func sessionFile(in profile: URL) -> URL? {
        let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/previous.jsonlz4"]
        return candidates.map { profile.appending(path: $0) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    public func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<8]) == magic else { return nil }
        let size = Int(PickleReader.uint32(bytes, at: 8))
        // One LZ4 block byte yields at most 255 bytes (a match-length byte), so a larger size is a lie
        // that would only allocate.
        guard size > 0, size <= maximumSize, size / 255 <= bytes.count - 12 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                // Both buffers are non-empty (checked above); without a base address nothing decodes.
                guard let target = destination.baseAddress, let input = source.baseAddress else { return 0 }
                return compression_decode_buffer(target, size, input + 12, bytes.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? Data(output) : nil
    }

    /// The open tabs; a tab with no history entry or an address that is not importable is counted.
    public func parse(_ data: Data) -> ImportRead<ImportedTab> {
        guard let json = decompress(data),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return ImportRead() }
        var read = ImportRead<ImportedTab>()
        for (windowIndex, window) in (root["windows"] as? [[String: Any]] ?? []).enumerated() {
            for element in window["tabs"] as? [Any] ?? [] {
                guard let tab = element as? [String: Any], let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else {
                    read.skipped.unsupported += 1
                    continue
                }
                // `index` is 1-based; any other number (Int.min included) picks the nearest entry.
                let index = min(max(tab["index"] as? Int ?? entries.count, 1), entries.count) - 1
                guard let text = entries[index]["url"] as? String, let url = ImportableURL.parse(text) else {
                    read.skipped.notImportable += 1
                    continue
                }
                let title = (entries[index]["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                read.items.append(ImportedTab(url: url, title: title, window: windowIndex, pinned: tab["pinned"] as? Bool ?? false))
            }
        }
        return read
    }
}
