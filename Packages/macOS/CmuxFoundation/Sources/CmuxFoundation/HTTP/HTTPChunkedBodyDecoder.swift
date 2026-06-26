import Foundation

/// Decodes an HTTP/1.1 `Transfer-Encoding: chunked` message body into the raw
/// payload bytes, enforcing a hard upper bound on the decoded size.
///
/// The decoder is a pure value over `Data`: it carries only the configured byte
/// ceiling and performs no I/O. Construct one with the maximum number of decoded
/// bytes to accept, then call ``decode(_:)`` with the accumulated chunked body.
public struct HTTPChunkedBodyDecoder: Sendable {
    /// The maximum number of decoded payload bytes to accept. Any chunk size,
    /// running total, or final length exceeding this rejects the whole body.
    public let maximumBytes: Int

    /// Creates a decoder bounded to `maximumBytes` decoded payload bytes.
    public init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    /// Decodes `data` as an HTTP/1.1 chunked body, returning the concatenated
    /// chunk payloads, or `nil` if the framing is malformed, a size header is
    /// invalid, the stream ends without a terminating zero-length chunk, or any
    /// size constraint is violated.
    public func decode(_ data: Data) -> Data? {
        let bytes = Array(data)
        var offset = 0
        var decoded = Data()

        while offset < bytes.count {
            guard let lineEnd = crlfIndex(in: bytes, from: offset) else { return nil }
            let sizeLineBytes = bytes[offset..<lineEnd]
            guard let sizeLine = String(bytes: sizeLineBytes, encoding: .ascii) else { return nil }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            offset = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let remainingBytes = bytes.count - offset
            guard size >= 0,
                  size <= maximumBytes,
                  decoded.count <= maximumBytes - size,
                  remainingBytes >= 2,
                  size <= remainingBytes - 2 else {
                return nil
            }
            let chunkEnd = offset + size
            guard bytes[chunkEnd] == 13,
                  bytes[chunkEnd + 1] == 10 else {
                return nil
            }
            decoded.append(contentsOf: bytes[offset..<offset + size])
            guard decoded.count <= maximumBytes else { return nil }
            offset += size + 2
        }
        return nil
    }

    private func crlfIndex(in bytes: [UInt8], from offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        var index = offset
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }
}
