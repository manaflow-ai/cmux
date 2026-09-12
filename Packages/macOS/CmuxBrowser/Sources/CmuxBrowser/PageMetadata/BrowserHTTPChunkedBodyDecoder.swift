import Foundation

/// Decodes one bounded HTTP/1 chunked response body.
struct BrowserHTTPChunkedBodyDecoder: Sendable {
    let maximumBytes: Int

    func decode(_ data: Data) -> Data? {
        let bytes = Array(data)
        var offset = 0
        var decoded = Data()

        while offset < bytes.count {
            guard let lineEnd = crlfIndex(in: bytes, from: offset),
                  let sizeLine = String(bytes: bytes[offset..<lineEnd], encoding: .ascii) else {
                return nil
            }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            offset = lineEnd + 2
            if size == 0 { return decoded }
            let remaining = bytes.count - offset
            guard size >= 0,
                  size <= maximumBytes,
                  decoded.count <= maximumBytes - size,
                  remaining >= size + 2 else {
                return nil
            }
            let chunkEnd = offset + size
            guard bytes[chunkEnd] == 13, bytes[chunkEnd + 1] == 10 else { return nil }
            decoded.append(contentsOf: bytes[offset..<chunkEnd])
            offset = chunkEnd + 2
        }
        return nil
    }

    private func crlfIndex(in bytes: [UInt8], from offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        for index in offset..<(bytes.count - 1) where bytes[index] == 13 && bytes[index + 1] == 10 {
            return index
        }
        return nil
    }
}
