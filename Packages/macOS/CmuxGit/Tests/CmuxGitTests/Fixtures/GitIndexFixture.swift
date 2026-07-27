import Foundation

/// A test-only builder for a binary git `index` file.
///
/// The production parser (`GitMetadataService.gitIndexSnapshot`) reads the magic,
/// version, entry count, and entries, and treats the trailing 20 bytes as an
/// opaque signature (it does not verify the SHA-1), so this builder fills the
/// trailer with arbitrary bytes. Supports versions 2 and 4 (path
/// prefix-compression) so tests can exercise both decode paths deterministically.
struct GitIndexFixture {
    struct Entry {
        var path: String
        var mode: UInt32 = 0o100644
        var objectID: String = String(repeating: "a", count: 40)
        var mtimeSeconds: UInt32 = 1
        var mtimeNanoseconds: UInt32 = 0
        var size: UInt32 = 0
        var assumeUnchanged: Bool = false
        var skipWorktree: Bool = false
    }

    var version: UInt32
    var entries: [Entry]
    var trailer: [UInt8]

    init(version: UInt32, entries: [Entry], trailer: [UInt8]? = nil) {
        self.version = version
        self.entries = entries
        self.trailer = trailer ?? Array(repeating: 0xAB, count: 20)
    }

    func data() -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("DIRC".utf8))
        bytes.append(contentsOf: Self.bigEndianUInt32(version))
        bytes.append(contentsOf: Self.bigEndianUInt32(UInt32(entries.count)))

        var previousPath: [UInt8] = []
        for entry in entries {
            let entryStart = bytes.count
            // ctime sec/nsec (unused by parser)
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            // mtime sec/nsec (offset +8, +12)
            bytes.append(contentsOf: Self.bigEndianUInt32(entry.mtimeSeconds))
            bytes.append(contentsOf: Self.bigEndianUInt32(entry.mtimeNanoseconds))
            // dev, ino (offset +16, +20; unused)
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            // mode (offset +24)
            bytes.append(contentsOf: Self.bigEndianUInt32(entry.mode))
            // uid, gid (offset +28, +32; unused)
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            bytes.append(contentsOf: Self.bigEndianUInt32(0))
            // size (offset +36)
            bytes.append(contentsOf: Self.bigEndianUInt32(entry.size))
            // object id (offset +40, 20 bytes)
            bytes.append(contentsOf: Self.hexBytes(entry.objectID))
            // flags (offset +60, 2 bytes)
            let pathBytes = Array(entry.path.utf8)
            var flags = UInt16(min(pathBytes.count, 0x0fff))
            if entry.assumeUnchanged { flags |= 0x8000 }
            let usesExtendedFlags = version >= 3 && entry.skipWorktree
            if usesExtendedFlags { flags |= 0x4000 }
            bytes.append(contentsOf: Self.bigEndianUInt16(flags))
            if usesExtendedFlags {
                let extended: UInt16 = entry.skipWorktree ? 0x4000 : 0
                bytes.append(contentsOf: Self.bigEndianUInt16(extended))
            }

            if version == 4 {
                let stripLength = commonPrefixLength(previousPath, pathBytes)
                bytes.append(contentsOf: Self.v4StripLengthVarint(previousPath.count - stripLength))
                bytes.append(contentsOf: pathBytes.suffix(pathBytes.count - stripLength))
                bytes.append(0)
            } else {
                bytes.append(contentsOf: pathBytes)
                bytes.append(0)
                let entryLength = bytes.count - entryStart
                let padding = (8 - (entryLength % 8)) % 8
                bytes.append(contentsOf: Array(repeating: 0, count: padding))
            }
            previousPath = pathBytes
        }

        bytes.append(contentsOf: trailer)
        return Data(bytes)
    }

    private func commonPrefixLength(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    static func bigEndianUInt32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func bigEndianUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func hexBytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, result.count < 20 {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                result.append(byte)
            }
            index = next
        }
        while result.count < 20 { result.append(0) }
        return result
    }

    /// Encodes the git index v4 path strip-length using varint.c's offset
    /// encoding (the inverse of the production decoder).
    static func v4StripLengthVarint(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        bytes.append(UInt8(remaining & 0x7f))
        remaining >>= 7
        while remaining != 0 {
            remaining -= 1
            bytes.insert(UInt8(0x80 | (remaining & 0x7f)), at: 0)
            remaining >>= 7
        }
        return bytes
    }
}
