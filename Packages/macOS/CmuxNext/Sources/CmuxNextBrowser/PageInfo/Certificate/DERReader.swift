import Foundation

/// One DER element: tag, the whole encoding, and the content octets.
nonisolated struct DERElement: Hashable, Sendable {
    let tag: UInt8
    /// Tag, length and content.
    let encoded: Data
    let content: Data

    var isConstructed: Bool { tag & 0x20 != 0 }

    /// Child elements of a constructed element (SEQUENCE, SET, explicit tags).
    func children() throws(DERError) -> [DERElement] {
        var reader = DERReader(content)
        var result: [DERElement] = []
        while !reader.isAtEnd { result.append(try reader.next()) }
        return result
    }

    /// OBJECT IDENTIFIER in dotted form.
    var objectIdentifier: String? {
        guard tag == 0x06, let first = content.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in content.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// Character strings (UTF8, Printable, IA5, T61, BMP, Universal).
    var string: String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14, 0x81, 0x82, 0x86: String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1)
        case 0x1E: String(data: content, encoding: .utf16BigEndian)
        case 0x1C: String(data: content, encoding: .utf32BigEndian)
        default: nil
        }
    }

    /// UTCTime or GeneralizedTime.
    var date: Date? {
        guard let text = String(data: content, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch tag {
        case 0x17: formatter.dateFormat = text.count > 11 && text.dropLast().count == 12 ? "yyMMddHHmmss" : "yyMMddHHmm"
        case 0x18: formatter.dateFormat = "yyyyMMddHHmmss"
        default: return nil
        }
        let trimmed = text.hasSuffix("Z") ? String(text.dropLast()) : text
        guard var date = formatter.date(from: trimmed) else { return nil }
        // RFC 5280: UTCTime years 50...99 are 19xx; DateFormatter may pick 20xx.
        if tag == 0x17, let year = Int(trimmed.prefix(2)), year >= 50,
           let fixed = Calendar(identifier: .gregorian).date(byAdding: .year, value: -100, to: date),
           Calendar(identifier: .gregorian).component(.year, from: date) >= 2050 {
            date = fixed
        }
        return date
    }

    /// INTEGER as a small value (version numbers).
    var integer: Int? {
        guard tag == 0x02, content.count <= 8 else { return nil }
        return content.reduce(0) { ($0 << 8) | Int($1) }
    }
}

nonisolated enum DERError: Error, Hashable, Sendable {
    case truncated
    case unsupportedLength
    case unexpected(String)
}

/// Sequential reader over DER bytes.
nonisolated struct DERReader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func next() throws(DERError) -> DERElement {
        let start = offset
        guard offset < data.endIndex else { throw .truncated }
        let tag = data[offset]
        offset += 1
        guard tag & 0x1F != 0x1F else { throw .unexpected("high tag number") }
        guard offset < data.endIndex else { throw .truncated }
        var length = Int(data[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4 else { throw .unsupportedLength }
            guard data.endIndex - offset >= count else { throw .truncated }
            length = data[offset ..< offset + count].reduce(0) { ($0 << 8) | Int($1) }
            offset += count
        }
        guard data.endIndex - offset >= length else { throw .truncated }
        let content = data[offset ..< offset + length]
        offset += length
        return DERElement(tag: tag, encoded: Data(data[start ..< offset]), content: Data(content))
    }
}
