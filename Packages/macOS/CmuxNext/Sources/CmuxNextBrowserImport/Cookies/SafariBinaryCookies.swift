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
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8) else { throw CookieImportError.malformed("binarycookies magic") }
        let pageCount = Int(try be32(bytes, 4))
        var offset = 8 + pageCount * 4
        var result = CookieReadResult(cookies: [])
        for page in 0..<pageCount {
            let size = Int(try be32(bytes, 8 + page * 4))
            guard size >= 8, offset + size <= bytes.count else { throw CookieImportError.malformed("page \(page)") }
            try parsePage(Array(bytes[offset..<offset + size]), now: now, into: &result)
            offset += size
        }
        return result
    }

    private func parsePage(_ page: [UInt8], now: Date, into result: inout CookieReadResult) throws {
        guard try be32(page, 0) == 0x0000_0100 else { throw CookieImportError.malformed("page header") }
        let count = Int(try le32(page, 4))
        for index in 0..<count {
            let start = Int(try le32(page, 8 + index * 4))
            guard start + 56 <= page.count else { throw CookieImportError.malformed("cookie \(index)") }
            let size = Int(try le32(page, start))
            guard size >= 56, start + size <= page.count else { throw CookieImportError.malformed("cookie \(index) size") }
            let record = Array(page[start..<start + size])
            let flags = try le32(record, 8)
            let cookie = ImportedCookie(
                name: try string(record, at: Int(try le32(record, 20))),
                value: try string(record, at: Int(try le32(record, 28))),
                domain: try string(record, at: Int(try le32(record, 16))),
                path: try string(record, at: Int(try le32(record, 24))),
                secure: flags & 1 != 0, httpOnly: flags & 4 != 0,
                expires: BrowserTime().cocoa(double(record, 40)), created: BrowserTime().cocoa(double(record, 48))
            )
            if cookie.isExpired(at: now) { result.expired += 1 } else { result.cookies.append(cookie) }
        }
    }

    private func be32(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        guard at + 4 <= bytes.count else { throw CookieImportError.malformed("truncated") }
        return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func le32(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        guard at + 4 <= bytes.count else { throw CookieImportError.malformed("truncated") }
        return bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func double(_ bytes: [UInt8], _ at: Int) -> Double {
        let bits = bytes[at..<at + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Double(bitPattern: bits)
    }

    private func string(_ bytes: [UInt8], at: Int) throws -> String {
        guard at > 0, at < bytes.count, let end = bytes[at...].firstIndex(of: 0) else { throw CookieImportError.malformed("string") }
        return String(decoding: bytes[at..<end], as: UTF8.self)
    }
}
