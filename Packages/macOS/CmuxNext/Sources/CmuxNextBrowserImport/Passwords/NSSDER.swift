import Foundation

// CMUX_NO_PASSWORD_IMPORT (set only by the cx-f58x notary test build,
// nightly.yml input notary_test_without_password_import) compiles out the
// browser password readers. Default builds include them.
#if !CMUX_NO_PASSWORD_IMPORT
/// The small part of DER that Firefox's NSS blobs use: SEQUENCE, OCTET
/// STRING, INTEGER and OBJECT IDENTIFIER, definite lengths only. The
/// encrypted blobs it reads hold no plaintext; decrypted bytes never pass
/// through here.
struct NSSDER: Sendable {
    struct Malformed: Error, Equatable {}

    static let sequence: UInt8 = 0x30
    static let octetString: UInt8 = 0x04
    static let integer: UInt8 = 0x02
    static let objectIdentifier: UInt8 = 0x06

    let tag: UInt8
    let content: [UInt8]

    /// One whole TLV; trailing bytes are refused.
    init(_ bytes: [UInt8]) throws(Malformed) {
        var index = 0
        self = try Self.next(bytes, &index)
        guard index == bytes.count else { throw Malformed() }
    }

    private init(tag: UInt8, content: [UInt8]) {
        self.tag = tag
        self.content = content
    }

    private static func next(_ bytes: [UInt8], _ index: inout Int) throws(Malformed) -> NSSDER {
        guard index + 2 <= bytes.count else { throw Malformed() }
        let tag = bytes[index]
        var length = Int(bytes[index + 1])
        index += 2
        if length & 0x80 != 0 {
            let octets = length & 0x7F
            guard (1...4).contains(octets), index + octets <= bytes.count else { throw Malformed() }
            length = 0
            for _ in 0..<octets {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, index + length <= bytes.count else { throw Malformed() }
        let content = Array(bytes[index..<index + length])
        index += length
        return NSSDER(tag: tag, content: content)
    }

    /// The elements of a SEQUENCE.
    func children() throws(Malformed) -> [NSSDER] {
        guard tag == Self.sequence else { throw Malformed() }
        var result: [NSSDER] = []
        var index = 0
        while index < content.count { result.append(try Self.next(content, &index)) } // wakeup-allow: each step consumes at least two bytes
        return result
    }

    func child(_ position: Int, tag expected: UInt8) throws(Malformed) -> NSSDER {
        let all = try children()
        guard position < all.count, all[position].tag == expected else { throw Malformed() }
        return all[position]
    }

    /// An OBJECT IDENTIFIER in dotted form ("1.2.840.113549.1.5.13").
    func oid() throws(Malformed) -> String {
        guard tag == Self.objectIdentifier, let first = content.first else { throw Malformed() }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            guard value < 1 << 28 else { throw Malformed() }
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// A small non-negative INTEGER (iteration counts and key lengths).
    func smallInteger() throws(Malformed) -> Int {
        guard tag == Self.integer, !content.isEmpty, content.count <= 4, content[0] & 0x80 == 0 else { throw Malformed() }
        return content.reduce(0) { $0 << 8 | Int($1) }
    }
}
#endif
