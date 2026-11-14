import Compression
import Foundation

/// A large acpmux message the Mac's mobile host sent compressed (CMUX-563): the phone asks for
/// it when it opens the `acpmux` channel (`args.compression = "deflate"`), and a host that
/// knows it sends each message of 16 KiB or more as one envelope, smaller ones and every
/// message of an older host as JSON text, as before (cmux-mobile-host `link_deflate.rs`):
///
/// ```text
/// 0x00 | text length (u32 BE) | deflate length (u32 BE) | raw deflate (RFC 1951) of the JSON text
/// ```
///
/// JSON never starts with 0x00, so the first byte tells the two apart. A session list is JSON
/// that deflates about 6x at the fastest level (acpmux `frame_compress.rs`: 1.2 MB to 0.2 MB).
/// The text length bounds the inflate: the phone allocates that much, at most
/// ``AcpmuxConnection/MessageJoiner/maxMessage``, and the message is refused unless the deflate
/// stream fills it exactly.
struct DeflatedMessage {
    static let marker: UInt8 = 0x00
    static let headerBytes = 9

    /// What `bytes`, an envelope's frames joined so far, hold.
    enum State: Equatable {
        /// More frames are needed.
        case waiting
        /// The whole JSON text, and how many bytes of `bytes` the envelope took.
        case whole(Data, used: Int)
        /// Not an envelope this phone can read (too large, or the deflate stream is bad).
        case bad
    }

    let textBytes: Int
    let deflateBytes: Int

    /// The header of `bytes`, once its nine bytes are in.
    init?(header bytes: Data) {
        guard bytes.count >= Self.headerBytes, bytes.first == Self.marker else { return nil }
        let start = bytes.startIndex
        func u32(_ at: Int) -> Int {
            (1...4).reduce(0) { $0 << 8 | Int(bytes[start + at + $1 - 1]) }
        }
        textBytes = u32(1)
        deflateBytes = u32(5)
    }

    static func state(_ bytes: Data, limit: Int) -> State {
        guard let header = DeflatedMessage(header: bytes) else { return bytes.count < headerBytes ? .waiting : .bad }
        guard header.textBytes > 0, header.textBytes <= limit, header.deflateBytes > 0, header.deflateBytes <= limit else { return .bad }
        let used = headerBytes + header.deflateBytes
        guard bytes.count >= used else { return .waiting }
        let body = bytes.subdata(in: (bytes.startIndex + headerBytes)..<(bytes.startIndex + used))
        guard let text = header.inflate(body) else { return .bad }
        return .whole(text, used: used)
    }

    /// The text of `body`, the envelope's deflate stream: exactly ``textBytes`` long, else nil.
    func inflate(_ body: Data) -> Data? {
        var text = Data(count: textBytes + 1)
        let written = text.withUnsafeMutableBytes { out -> Int in
            body.withUnsafeBytes { input -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // One byte of room past the length: a stream that inflates longer is refused.
                return compression_decode_buffer(dst, textBytes + 1, src, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == textBytes else { return nil }
        text.count = textBytes
        return text
    }
}
