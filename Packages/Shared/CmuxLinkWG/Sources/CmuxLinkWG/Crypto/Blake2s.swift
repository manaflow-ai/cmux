/// BLAKE2s (RFC 7693), unkeyed or keyed, 1 to 32 byte output. WireGuard's
/// HASH, MAC and (inside HMAC) KDF. CryptoKit has no BLAKE2s.
struct Blake2s {
    enum ParameterError: Error, Equatable {
        case invalidOutputLength
        case keyTooLong
    }

    static let blockLength = 64

    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var state: [UInt32]
    private var buffer: [UInt8] = []
    private var counter: UInt64 = 0
    private let outputLength: Int

    init() {
        outputLength = 32
        state = Self.iv
        state[0] ^= 0x0101_0020
    }

    /// Creates a hasher for the RFC 7693 parameter range. Invalid parameters
    /// are rejected at the boundary instead of trapping the process.
    init(outputLength: Int, key: [UInt8]) throws {
        guard (1...32).contains(outputLength) else { throw ParameterError.invalidOutputLength }
        guard key.count <= 32 else { throw ParameterError.keyTooLong }
        self.outputLength = outputLength
        state = Self.iv
        state[0] ^= 0x0101_0000 ^ (UInt32(key.count) << 8) ^ UInt32(outputLength)
        if !key.isEmpty {
            buffer = key + [UInt8](repeating: 0, count: Self.blockLength - key.count)
        }
    }

    mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes {
            // The last block is compressed in finalize with the final flag,
            // so a full buffer is only flushed when more input arrives.
            if buffer.count == Self.blockLength {
                counter &+= UInt64(Self.blockLength)
                compress(final: false)
                buffer.removeAll(keepingCapacity: true)
            }
            buffer.append(byte)
        }
    }

    mutating func finalize() -> [UInt8] {
        counter &+= UInt64(buffer.count)
        buffer += [UInt8](repeating: 0, count: Self.blockLength - buffer.count)
        compress(final: true)
        var output: [UInt8] = []
        output.reserveCapacity(32)
        for word in state {
            output += [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF), UInt8(word >> 24)]
        }
        return Array(output.prefix(outputLength))
    }

    static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = Blake2s()
        for part in parts { hasher.update(part) }
        return hasher.finalize()
    }

    static func hash(_ parts: [UInt8]..., outputLength: Int = 32, key: [UInt8]) throws -> [UInt8] {
        var hasher = try Blake2s(outputLength: outputLength, key: key)
        for part in parts { hasher.update(part) }
        return hasher.finalize()
    }

    private mutating func compress(final: Bool) {
        var m = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            let base = index * 4
            m[index] = UInt32(buffer[base]) | UInt32(buffer[base + 1]) << 8
                | UInt32(buffer[base + 2]) << 16 | UInt32(buffer[base + 3]) << 24
        }
        var v = state + Self.iv
        v[12] ^= UInt32(truncatingIfNeeded: counter)
        v[13] ^= UInt32(truncatingIfNeeded: counter >> 32)
        if final { v[14] = ~v[14] }
        for round in 0..<10 {
            let s = Self.sigma[round]
            Self.mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            Self.mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            Self.mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            Self.mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            Self.mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            Self.mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            Self.mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            Self.mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for index in 0..<8 { state[index] ^= v[index] ^ v[index + 8] }
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], 8)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 7)
    }

    @inline(__always)
    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
