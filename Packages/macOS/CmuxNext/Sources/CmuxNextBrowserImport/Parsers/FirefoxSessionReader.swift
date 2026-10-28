public import Foundation
import Compression
import CmuxNextCompat

/// Reads the open tabs of Firefox's session store. The file is "mozLz4":
/// the magic `mozLz40\0`, a little-endian uint32 decompressed size, then one
/// raw LZ4 block holding JSON (`windows[].tabs[].entries[]`, `index` 1-based).
public struct FirefoxSessionReader {

    /// Creates a reader of Firefox sessions.
    public init() {}

    let magic = Array("mozLz40\0".utf8)
    /// Session stores above this size are not read (a sane upper bound).
    let maximumSize = 256 * 1024 * 1024

    public func sessionFile(in profile: URL) -> URL? {
        let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/previous.jsonlz4"]
        return candidates.map { profile.appending(path: $0) }.first { FileManager.checked.fileExists(atPath: $0.path) }
    }

    public func decompress(_ data: Data) -> Data? {
        guard data.count > 12, data.prefix(8).elementsEqual(magic), let size = PickleReader.uint32(data.dropFirst(8))?.widened
        else { return nil }
        let block = [UInt8](data.dropFirst(12))
        // One LZ4 block byte yields at most 255 bytes (a match-length byte), so a larger size is a lie
        // that would only allocate.
        guard size > 0, size <= maximumSize, size / 255 <= block.count else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        // SAFETY: the decoder reads at most block.count bytes of `block` and writes at most `size`
        // (output.count) bytes into `output`, the counts passed; Swift lends both arrays for the call.
        let written = unsafe compression_decode_buffer(&output, size, block, block.count, nil, COMPRESSION_LZ4_RAW)
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
                // `index` is 1-based; any other number (Int.min included) picks the nearest entry, as Firefox
                // restores it (SessionStore.sys.mjs restoreTab: the index is kept inside the entries).
                let index = min(max(tab["index"] as? Int ?? entries.count, 1), entries.count) - 1
                guard let entry = entries[checked: index], let text = entry["url"] as? String, let url = ImportableURL.parse(text) else {
                    read.skipped.notImportable += 1
                    continue
                }
                let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                read.items.append(ImportedTab(url: url, title: title, window: windowIndex, pinned: tab["pinned"] as? Bool ?? false))
            }
        }
        return read
    }
}
