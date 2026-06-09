import Foundation

// Parses Safari's Cookies.binarycookies binary format.
// Format uses mixed endianness: file header is big-endian, all page and cookie
// fields are little-endian. Timestamps are LE IEEE-754 doubles in Mac absolute
// time (seconds since 2001-01-01); add 978_307_200 to convert to Unix epoch.
enum SafariBinaryCookiesParser {
    struct ParsedCookie: Sendable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHttpOnly: Bool
    }

    enum ParseError: LocalizedError {
        case tooShort
        case invalidMagic
        case pageOutOfBounds(Int)
        case cookieOutOfBounds(Int)

        // User-facing copy stays product-level and action-oriented. The page/cookie
        // indices carried by the associated values are diagnostics, not shown to
        // users; a caller can log them if needed.
        var errorDescription: String? {
            switch self {
            case .tooShort:
                return String(
                    localized: "safari.cookies.parse.error.tooShort",
                    defaultValue: "The Safari cookies file appears incomplete. Try re-exporting it from Safari, then import again."
                )
            case .invalidMagic:
                return String(
                    localized: "safari.cookies.parse.error.invalidMagic",
                    defaultValue: "This file isn't a recognizable Safari cookies file."
                )
            case .pageOutOfBounds, .cookieOutOfBounds:
                return String(
                    localized: "safari.cookies.parse.error.corrupted",
                    defaultValue: "The Safari cookies file appears to be corrupted. Try re-exporting it from Safari, then import again."
                )
            }
        }
    }

    static func parse(fileURL: URL) throws -> [ParsedCookie] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try parse(data: data)
    }

    static func parse(data rawData: Data) throws -> [ParsedCookie] {
        // Normalize to a buffer whose startIndex is 0 so all offset arithmetic
        // below (including the magic check and readCString bounds) is consistent
        // even if the caller passes a Data slice.
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        guard data.count >= 8 else { throw ParseError.tooShort }

        // Magic: "cook" (0x636F6F6B)
        guard data[0] == 0x63, data[1] == 0x6F, data[2] == 0x6F, data[3] == 0x6B
        else { throw ParseError.invalidMagic }

        let pageCount = Int(readBEUInt32(data, offset: 4))
        let pageSizesEnd = 8 + pageCount * 4
        guard data.count >= pageSizesEnd else { throw ParseError.tooShort }

        var fileOffset = pageSizesEnd
        var result: [ParsedCookie] = []

        for pageIndex in 0 ..< pageCount {
            let pageSize = Int(readBEUInt32(data, offset: 8 + pageIndex * 4))
            guard fileOffset + pageSize <= data.count else {
                throw ParseError.pageOutOfBounds(pageIndex)
            }
            let pageData = data[fileOffset ..< fileOffset + pageSize]
            let pageCookies = try parsePage(Data(pageData), pageIndex: pageIndex)
            result.append(contentsOf: pageCookies)
            fileOffset += pageSize
        }

        return result
    }

    // MARK: - Page parsing

    private static func parsePage(_ page: Data, pageIndex: Int) throws -> [ParsedCookie] {
        // Page header: 4-byte signature, LE UInt32 cookie count, cookie offsets
        guard page.count >= 8 else { return [] }

        let cookieCount = Int(readLEUInt32(page, offset: 4))
        guard page.count >= 8 + cookieCount * 4 else { return [] }

        var cookies: [ParsedCookie] = []
        for i in 0 ..< cookieCount {
            let cookieOffset = Int(readLEUInt32(page, offset: 8 + i * 4))
            guard cookieOffset < page.count else {
                throw ParseError.cookieOutOfBounds(i)
            }
            if let cookie = parseCookie(page, at: cookieOffset) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    // MARK: - Cookie record parsing

    private static func parseCookie(_ page: Data, at offset: Int) -> ParsedCookie? {
        // Fixed 56-byte header (all little-endian)
        guard offset + 56 <= page.count else { return nil }

        let cookieSize = Int(readLEUInt32(page, offset: offset + 0))
        guard cookieSize > 56, offset + cookieSize <= page.count else { return nil }

        let flags = readLEUInt32(page, offset: offset + 8)
        let domainOff = Int(readLEUInt32(page, offset: offset + 16))
        let nameOff   = Int(readLEUInt32(page, offset: offset + 20))
        let pathOff   = Int(readLEUInt32(page, offset: offset + 24))
        let valueOff  = Int(readLEUInt32(page, offset: offset + 28))

        let expiryMac  = readLEDouble(page, offset: offset + 40)
        // Skip creation at offset+48; not needed for HTTPCookie

        let domain = readCString(page, from: offset + domainOff, to: offset + nameOff)
        let name   = readCString(page, from: offset + nameOff,   to: offset + pathOff)
        let path   = readCString(page, from: offset + pathOff,   to: offset + valueOff)
        let value  = readCString(page, from: offset + valueOff,  to: offset + cookieSize)

        let expiresDate: Date? = (expiryMac.isFinite && expiryMac > 0)
            ? Date(timeIntervalSince1970: expiryMac + 978_307_200)
            : nil

        return ParsedCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expiresDate: expiresDate,
            isSecure: (flags & 0x01) != 0,
            isHttpOnly: (flags & 0x04) != 0
        )
    }

    // MARK: - Binary reading helpers

    private static func readBEUInt32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readLEUInt32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readLEDouble(_ data: Data, offset: Int) -> Double {
        var bits: UInt64 = 0
        for i in 0 ..< 8 {
            bits |= UInt64(data[data.startIndex + offset + i]) << (i * 8)
        }
        return Double(bitPattern: bits)
    }

    // Reads a null-terminated string in [from, to); strips the null terminator.
    private static func readCString(_ data: Data, from: Int, to: Int) -> String {
        guard from >= 0, to > from, to <= data.startIndex + data.count else { return "" }
        let start = data.startIndex + from
        let end   = data.startIndex + to
        // Find null terminator within range
        var len = 0
        while start + len < end, data[start + len] != 0 { len += 1 }
        guard len > 0 else { return "" }
        return String(data: data[start ..< start + len], encoding: .utf8) ?? ""
    }
}
