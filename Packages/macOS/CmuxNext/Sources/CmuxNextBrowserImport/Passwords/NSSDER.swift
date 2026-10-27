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
        var rest = ArraySlice(bytes)
        self = try Self.next(&rest)
        guard rest.isEmpty else { throw Malformed() }
    }

    private init(tag: UInt8, content: [UInt8]) {
        self.tag = tag
        self.content = content
    }

    /// The TLV at the front of `rest`, which then holds what follows it. Read from the front, so a length the
    /// blob lies about is `Malformed`, never an index past the end (BoringSSL's CBS_get_asn1 reads the same way).
    private static func next(_ rest: inout ArraySlice<UInt8>) throws(Malformed) -> NSSDER {
        guard let tag = rest.popFirst(), let first = rest.popFirst() else { throw Malformed() }
        var length = first.widened
        if first & 0x80 != 0 {
            let count = (first & 0x7F).widened
            let octets = rest.prefix(count)
            guard (1...4).contains(count), octets.count == count else { throw Malformed() }
            length = octets.bigEndian(as: UInt32.self).widened
            rest = rest.dropFirst(count)
        }
        guard length <= rest.count else { throw Malformed() }
        let content = Array(rest.prefix(length))
        rest = rest.dropFirst(length)
        return NSSDER(tag: tag, content: content)
    }

    /// The elements of a SEQUENCE.
    func children() throws(Malformed) -> [NSSDER] {
        guard tag == Self.sequence else { throw Malformed() }
        var result: [NSSDER] = []
        var rest = ArraySlice(content)
        while !rest.isEmpty { result.append(try Self.next(&rest)) } // wakeup-allow: bounded each step consumes at least two bytes
        return result
    }

    func child(_ position: Int, tag expected: UInt8) throws(Malformed) -> NSSDER {
        guard let element = try children()[checked: position], element.tag == expected else { throw Malformed() }
        return element
    }

    /// An OBJECT IDENTIFIER in dotted form ("1.2.840.113549.1.5.13").
    func oid() throws(Malformed) -> String {
        guard tag == Self.objectIdentifier, let first = content.first else { throw Malformed() }
        var parts = [first.widened / 40, first.widened % 40]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | (byte & 0x7F).widened
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
        guard tag == Self.integer, let sign = content.first, content.count <= 4, sign & 0x80 == 0 else { throw Malformed() }
        return content.bigEndian(as: UInt32.self).widened
    }
}
#endif
