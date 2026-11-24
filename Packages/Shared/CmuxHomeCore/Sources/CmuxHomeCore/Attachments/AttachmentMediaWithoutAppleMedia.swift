#if !canImport(ImageIO)
import Foundation

/// ``AttachmentMedia`` where Apple's media frameworks (AVFoundation,
/// ImageIO, CryptoKit, UniformTypeIdentifiers) are missing: the Linux
/// package lane (scripts/ci/swift-linux-packages.txt), which runs the
/// store, wire and model tests. Hashing and the blob cache work; preparing,
/// converting or thumbnailing media throws `HomeRejection.invalid("media_unavailable")`.
enum AttachmentMedia {
    static func sha256(of data: Data) -> String { PortableSHA256.hex(of: data) }

    /// The allow list's extension for a mime type, the shortest then the
    /// first alphabetically (no UTType tables here).
    static func preferredFilenameExtension(forMimeType mimeType: String) -> String? {
        let mime = HomeAttachmentPolicy.canonicalMimeType(mimeType)
        return HomeAttachmentPolicy.extensionTypes.filter { $0.value == mime }.keys
            .min { ($0.count, $0) < ($1.count, $1) }
    }

    static func prepare(fileURL: URL, root: URL, name: String? = nil, keepLocation: Bool = false) async throws -> LocalAttachment {
        throw HomeRejection.invalid("media_unavailable")
    }

    static func prepare(data: Data, typeIdentifier: String, root: URL, name: String? = nil,
                        keepLocation: Bool = false) async throws -> LocalAttachment {
        throw HomeRejection.invalid("media_unavailable")
    }

    static func prepareLinkPreviewImage(fileURL: URL, root: URL) throws -> LocalAttachment {
        throw HomeRejection.invalid("media_unavailable")
    }

    static func thumbnailJPEG(of url: URL, maxPixel: Int, quality: Double = 0.85) throws -> Data {
        throw HomeRejection.invalid("media_unavailable")
    }

    static func localThumbnail(of files: LocalAttachmentFiles, ref: AttachmentRef, maxPixel: Int) throws -> URL {
        throw HomeRejection.invalid("media_unavailable")
    }
}

/// SHA-256 (FIPS 180-4) without CryptoKit, as lowercase hex.
enum PortableSHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    static func hex(of data: Data) -> String {
        var hash: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var w = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let at = block + 4 * i
                w[i] = UInt32(message[at]) << 24 | UInt32(message[at + 1]) << 16 | UInt32(message[at + 2]) << 8 | UInt32(message[at + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for i in 0..<64 {
                let t1 = h &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ roundConstants[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            for (i, value) in [a, b, c, d, e, f, g, h].enumerated() { hash[i] = hash[i] &+ value }
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
}
#endif
