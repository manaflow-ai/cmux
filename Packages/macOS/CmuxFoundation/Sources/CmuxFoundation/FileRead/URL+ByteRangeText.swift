public import Foundation

extension URL {
    /// Reads up to `byteCap` bytes from the start of this file URL and decodes
    /// them as UTF-8, falling back to a lossy decode of the same bytes.
    ///
    /// Returns the empty string when the file cannot be opened.
    public func readFileHead(byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return "" }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Reads up to `byteCap` bytes from the end of this file URL and decodes them
    /// as UTF-8. Used to find late-arriving events like pr-link without scanning
    /// the whole file.
    ///
    /// When the tail was cut mid-record, the leading partial line is trimmed.
    /// Returns the empty string when the file cannot be opened or is empty.
    public func readFileTail(byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return "" }
        defer { try? handle.close() }
        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return "" }
        if size == 0 { return "" }
        let cap = UInt64(byteCap)
        let offset: UInt64 = size > cap ? size - cap : 0
        do { try handle.seek(toOffset: offset) } catch { return "" }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteCap)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteCap)
        }
        // Trim leading partial line (we likely cut mid-record).
        if offset > 0, let nl = data.firstIndex(of: 0x0a) {
            return String(data: data[(nl + 1)...], encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
