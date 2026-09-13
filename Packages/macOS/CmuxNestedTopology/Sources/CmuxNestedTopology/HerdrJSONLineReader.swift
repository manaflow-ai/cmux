import Foundation

/// Incremental newline-delimited JSON line splitter with a hard byte bound.
struct HerdrJSONLineReader: Sendable {
    private(set) var buffer = Data()
    let maxLineUTF8ByteCount: Int

    /// Creates a reader that rejects lines larger than `maxLineUTF8ByteCount`.
    init(maxLineUTF8ByteCount: Int) {
        self.maxLineUTF8ByteCount = maxLineUTF8ByteCount
    }

    /// Appends raw socket bytes and returns every complete line decoded as UTF-8 (without the newline).
    mutating func append(_ data: Data) throws -> [String] {
        if data.isEmpty { return [] }
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            let nextIndex = buffer.index(after: newlineIndex)
            buffer.removeSubrange(buffer.startIndex..<nextIndex)
            if lineData.count > maxLineUTF8ByteCount {
                throw NestedTopologyProviderError.oversizedLine(maxUTF8ByteCount: maxLineUTF8ByteCount)
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw NestedTopologyProviderError.invalidUTF8
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        if buffer.count > maxLineUTF8ByteCount {
            throw NestedTopologyProviderError.oversizedLine(maxUTF8ByteCount: maxLineUTF8ByteCount)
        }
        return lines
    }
}
