public import Foundation
import Compression

/// Reads the open tabs of Firefox's session store. The file is "mozLz4":
/// the magic `mozLz40\0`, a little-endian uint32 decompressed size, then one
/// raw LZ4 block holding JSON (`windows[].tabs[].entries[]`, `index` 1-based).
public enum FirefoxSessionReader {
    static let magic = Array("mozLz40\0".utf8)
    /// Session stores above this size are not read (a sane upper bound).
    static let maximumSize = 256 * 1024 * 1024

    public static func sessionFile(in profile: URL) -> URL? {
        let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/previous.jsonlz4"]
        return candidates.map { profile.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<8]) == magic else { return nil }
        let size = Int(PickleReader.uint32(bytes, at: 8))
        guard size > 0, size <= maximumSize else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, size, source.baseAddress! + 12, bytes.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? Data(output) : nil
    }

    public static func parse(_ data: Data) -> [ImportedTab] {
        guard let json = decompress(data),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        var tabs: [ImportedTab] = []
        for (windowIndex, window) in (root["windows"] as? [[String: Any]] ?? []).enumerated() {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                let entries = tab["entries"] as? [[String: Any]] ?? []
                guard !entries.isEmpty else { continue }
                let index = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), entries.count - 1)
                guard let text = entries[index]["url"] as? String, let url = ImportableURL.parse(text) else { continue }
                let title = (entries[index]["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                tabs.append(ImportedTab(url: url, title: title, window: windowIndex, pinned: tab["pinned"] as? Bool ?? false))
            }
        }
        return tabs
    }
}
