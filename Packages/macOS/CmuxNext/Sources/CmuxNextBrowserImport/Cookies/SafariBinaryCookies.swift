public import Foundation

/// Parses Safari's `Cookies.binarycookies`: a big-endian file header
/// ("cook", page count, page sizes), then pages of little-endian cookie
/// records. Each record has flags (1 secure, 4 HttpOnly), offsets to
/// NUL-terminated domain, name, path and value strings, and expiry and
/// creation as Core Foundation absolute times (doubles).
public struct SafariBinaryCookies {
    /// Creates a parser for Safari binary cookies.
    public init() {}

    public func parse(_ data: Data, now: Date = Date()) throws -> CookieReadResult {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.starts(with: "cook".utf8) else { throw CookieImportError.malformed("binarycookies magic") }
        let pageCount = try be32(bytes, 4).widened
        var offset = 8 + pageCount * 4
        var result = CookieReadResult(cookies: [])
        for page in 0..<pageCount {
            let size = try be32(bytes, 8 + page * 4).widened
            guard size >= 8, offset + size <= bytes.count else { throw CookieImportError.malformed("page \(page)") }
            try parsePage(Array(bytes.dropFirst(offset).prefix(size)), now: now, into: &result)
            offset += size
        }
        return result
    }

    private func parsePage(_ page: [UInt8], now: Date, into result: inout CookieReadResult) throws {
        guard try be32(page, 0) == 0x0000_0100 else { throw CookieImportError.malformed("page header") }
        let count = try le32(page, 4).widened
        for index in 0..<count {
            let start = try le32(page, 8 + index * 4).widened
            guard start + 56 <= page.count else { throw CookieImportError.malformed("cookie \(index)") }
            let size = try le32(page, start).widened
            guard size >= 56, start + size <= page.count else { throw CookieImportError.malformed("cookie \(index) size") }
            let record = Array(page.dropFirst(start).prefix(size))
            let flags = try le32(record, 8)
            let cookie = ImportedCookie(
                name: try string(record, at: try le32(record, 20).widened),
                value: try string(record, at: try le32(record, 28).widened),
                domain: try string(record, at: try le32(record, 16).widened),
                path: try string(record, at: try le32(record, 24).widened),
                secure: flags & 1 != 0, httpOnly: flags & 4 != 0,
                expires: BrowserTime().cocoaExpiry(double(record, 40)), created: BrowserTime().cocoa(double(record, 48))
            )
            if cookie.isExpired(at: now) { result.expired += 1 } else { result.cookies.append(cookie) }
        }
    }

    /// The 4 bytes at `at` (never negative: a constant or a widened unsigned field), or `malformed` past the end.
    private func field(_ bytes: [UInt8], _ at: Int) throws -> ArraySlice<UInt8> {
        let field = bytes.dropFirst(at).prefix(4)
        guard field.count == 4 else { throw CookieImportError.malformed("truncated") }
        return field
    }

    private func be32(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        try field(bytes, at).bigEndian(as: UInt32.self)
    }

    private func le32(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        try field(bytes, at).littleEndian(as: UInt32.self)
    }

    /// The double at `at`; a record is at least 56 bytes (checked), so 40 and 48 are inside.
    private func double(_ bytes: [UInt8], _ at: Int) -> Double {
        Double(bitPattern: bytes.dropFirst(at).prefix(8).littleEndian(as: UInt64.self))
    }

    private func string(_ bytes: [UInt8], at: Int) throws -> String {
        let tail = bytes.dropFirst(at)
        guard at > 0, let end = tail.firstIndex(of: 0) else { throw CookieImportError.malformed("string") }
        return String(decoding: tail.prefix(upTo: end), as: UTF8.self)
    }
}
