import Foundation
import Testing

@testable import CmuxBrowser

/// Builds `Cookies.binarycookies` bytes the way Safari lays them out: a
/// big-endian file header and page table, little-endian page and cookie
/// records, and null-terminated strings addressed by offsets relative to the
/// start of each cookie record.
private struct BinaryCookiesFixture {
    struct Cookie {
        var domain: String
        var name: String
        var path: String
        var value: String
        /// Mac absolute time (seconds since 2001-01-01). `0` means a session cookie.
        var expiry: Double
        var flags: UInt32
        /// Bytes Safari may add between the fixed header and the strings.
        var extraHeaderBytes: [UInt8] = []
        /// Bytes after the strings but still inside the record.
        var trailingBytes: [UInt8] = []
        /// Drop the null terminator of the value string, as a truncated record would.
        var omitValueTerminator = false
    }

    static let secureFlag: UInt32 = 0x1
    static let httpOnlyFlag: UInt32 = 0x4
    static let fixedHeaderSize = 56

    /// A store holding `pages`, each encoded with ``page(_:)``.
    static func file(pages: [[Cookie]], trailer: [UInt8] = []) -> Data {
        file(encodedPages: pages.map(page), trailer: trailer)
    }

    /// A store whose page table points at `encodedPages`, followed by `trailer`.
    static func file(encodedPages: [[UInt8]], trailer: [UInt8] = []) -> Data {
        var bytes: [UInt8] = Array("cook".utf8)
        bytes += bigEndian(UInt32(encodedPages.count))
        for encodedPage in encodedPages {
            bytes += bigEndian(UInt32(encodedPage.count))
        }
        for encodedPage in encodedPages {
            bytes += encodedPage
        }
        bytes += trailer
        return Data(bytes)
    }

    /// A page holding `cookies` in order.
    static func page(_ cookies: [Cookie]) -> [UInt8] {
        page(records: cookies.map(record))
    }

    /// A page whose offset table points `times` entries at one stored record.
    static func pageRepeatingOneRecord(_ cookie: Cookie, times: Int) -> [UInt8] {
        let encodedRecord = record(cookie)
        var bytes: [UInt8] = [0x00, 0x00, 0x01, 0x00]
        bytes += littleEndian(UInt32(times))
        let offset = 8 + 4 * times + 4
        for _ in 0..<times {
            bytes += littleEndian(UInt32(offset))
        }
        bytes += [0x00, 0x00, 0x00, 0x00]
        bytes += encodedRecord
        return bytes
    }

    /// A page holding already-encoded `records` in order.
    static func page(records: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x00, 0x01, 0x00]
        bytes += littleEndian(UInt32(records.count))
        var offset = 8 + 4 * records.count + 4
        for encodedRecord in records {
            bytes += littleEndian(UInt32(offset))
            offset += encodedRecord.count
        }
        bytes += [0x00, 0x00, 0x00, 0x00]
        for encodedRecord in records {
            bytes += encodedRecord
        }
        return bytes
    }

    /// The encoded record for `cookie`: fixed header, then its strings.
    static func record(_ cookie: Cookie) -> [UInt8] {
        var strings = [cookie.domain, cookie.name, cookie.path, cookie.value].map { Array($0.utf8) + [0] }
        if cookie.omitValueTerminator {
            strings[3].removeLast()
        }
        var offsets: [UInt32] = []
        var cursor = fixedHeaderSize + cookie.extraHeaderBytes.count
        for string in strings {
            offsets.append(UInt32(cursor))
            cursor += string.count
        }
        let size = cursor + cookie.trailingBytes.count

        var bytes: [UInt8] = []
        bytes += littleEndian(UInt32(size))
        bytes += littleEndian(UInt32(0)) // version
        bytes += littleEndian(cookie.flags)
        bytes += littleEndian(UInt32(0)) // has port
        for offset in offsets {
            bytes += littleEndian(offset)
        }
        bytes += littleEndian(UInt32(0)) // comment offset
        bytes += littleEndian(UInt32(0)) // comment URL offset
        bytes += littleEndian(cookie.expiry.bitPattern)
        bytes += littleEndian(Double(0).bitPattern) // creation
        bytes += cookie.extraHeaderBytes
        for string in strings {
            bytes += string
        }
        bytes += cookie.trailingBytes
        return bytes
    }

    /// `value` as four big-endian bytes.
    static func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    /// `value` as little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    /// `value` as little-endian bytes.
    static func littleEndian(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}

/// Decoding of Safari's binary cookie store, including the malformed inputs a
/// user-selected file can present.
@Suite struct SafariBinaryCookiesParserTests {
    private let parser = SafariBinaryCookiesParser()

    private let sessionCookie = BinaryCookiesFixture.Cookie(
        domain: ".example.com",
        name: "session",
        path: "/",
        value: "abc123",
        expiry: 1_000_000_000,
        flags: BinaryCookiesFixture.secureFlag | BinaryCookiesFixture.httpOnlyFlag
    )

    private let themeCookie = BinaryCookiesFixture.Cookie(
        domain: "api.example.com",
        name: "theme",
        path: "/settings",
        value: "dark",
        expiry: 0,
        flags: 0
    )

    /// Decodes every field of a two-cookie store.
    @Test func decodesEveryFieldOfATwoCookieStore() throws {
        let data = BinaryCookiesFixture.file(pages: [[sessionCookie, themeCookie]])

        let cookies = try parser.parse(data)

        #expect(cookies.count == 2)
        let first = try #require(cookies.first)
        #expect(first.domain == ".example.com")
        #expect(first.name == "session")
        #expect(first.path == "/")
        #expect(first.value == "abc123")
        #expect(first.expiresDate == Date(timeIntervalSinceReferenceDate: 1_000_000_000))
        #expect(first.isSecure)
        #expect(first.isHTTPOnly)

        let second = try #require(cookies.last)
        #expect(second.domain == "api.example.com")
        #expect(second.name == "theme")
        #expect(second.path == "/settings")
        #expect(second.value == "dark")
        #expect(second.expiresDate == nil)
        #expect(!second.isSecure)
        #expect(!second.isHTTPOnly)
    }

    /// Collects cookies across pages.
    @Test func collectsCookiesAcrossPages() throws {
        let data = BinaryCookiesFixture.file(pages: [[sessionCookie], [themeCookie]])

        let cookies = try parser.parse(data)

        #expect(cookies.map(\.name) == ["session", "theme"])
    }

    /// A zero or non-finite expiry decodes as a session cookie.
    @Test(arguments: [Double.nan, -Double.infinity, Double.infinity, 0])
    func treatsZeroOrNonFiniteExpiryAsASessionCookie(_ expiry: Double) throws {
        var cookie = sessionCookie
        cookie.expiry = expiry
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        let cookies = try parser.parse(data)

        #expect(cookies.count == 1)
        #expect(cookies.first?.expiresDate == nil)
    }

    /// Preserves a negative expiry as an already-expired date.
    @Test func preservesANegativeExpiryAsAnAlreadyExpiredDate() throws {
        var cookie = sessionCookie
        cookie.expiry = -1
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        let cookies = try parser.parse(data)

        #expect(cookies.first?.expiresDate == Date(timeIntervalSinceReferenceDate: -1))
    }

    /// The Secure and HttpOnly flag bits decode independently of each other.
    @Test(arguments: [
        (flags: UInt32(0x1), secure: true, httpOnly: false),
        (flags: UInt32(0x4), secure: false, httpOnly: true),
        (flags: UInt32(0x5), secure: true, httpOnly: true),
        (flags: UInt32(0), secure: false, httpOnly: false),
    ])
    func decodesSecureAndHTTPOnlyIndependently(_ expectation: (flags: UInt32, secure: Bool, httpOnly: Bool)) throws {
        var cookie = sessionCookie
        cookie.flags = expectation.flags
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        let decoded = try #require(try parser.parse(data).first)

        #expect(decoded.isSecure == expectation.secure)
        #expect(decoded.isHTTPOnly == expectation.httpOnly)
    }

    /// The SameSite bits decode as CFNetwork writes them: `0x08` alone is Lax,
    /// `0x08` with `0x10` is Strict, and `0x10` alone or neither bit is no
    /// policy. The flag words are the ones `HTTPCookieStorage` wrote for cookies
    /// with those attributes, so the high bits every real record carries are
    /// covered too.
    @Test(arguments: [
        (flags: UInt32(0x4208), sameSite: SafariBinaryCookie.SameSite?.some(.lax)),
        (flags: UInt32(0x4218), sameSite: SafariBinaryCookie.SameSite?.some(.strict)),
        (flags: UInt32(0x421D), sameSite: SafariBinaryCookie.SameSite?.some(.strict)),
        (flags: UInt32(0x4210), sameSite: SafariBinaryCookie.SameSite?.none),
        (flags: UInt32(0x4230), sameSite: SafariBinaryCookie.SameSite?.none),
        (flags: UInt32(0x5), sameSite: SafariBinaryCookie.SameSite?.none),
    ])
    func decodesTheSameSitePolicy(_ expectation: (flags: UInt32, sameSite: SafariBinaryCookie.SameSite?)) throws {
        var cookie = sessionCookie
        cookie.flags = expectation.flags
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        let decoded = try #require(try parser.parse(data).first)

        #expect(decoded.sameSite == expectation.sameSite)
    }

    /// Secure and HttpOnly still decode from a flag word that carries SameSite and the high bits.
    @Test func decodesSecureAndHTTPOnlyBesideSameSite() throws {
        var cookie = sessionCookie
        cookie.flags = 0x421D
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        let decoded = try #require(try parser.parse(data).first)

        #expect(decoded.isSecure)
        #expect(decoded.isHTTPOnly)
    }

    /// An empty store decodes to no cookies.
    @Test func emptyStoreDecodesToNoCookies() throws {
        #expect(try parser.parse(BinaryCookiesFixture.file(pages: [])).isEmpty)
        #expect(try parser.parse(BinaryCookiesFixture.file(pages: [[]])).isEmpty)
    }

    /// Ignores trailer and unknown record bytes.
    @Test func ignoresTrailerAndUnknownRecordBytes() throws {
        var padded = sessionCookie
        padded.extraHeaderBytes = [0xAA, 0xBB, 0xCC, 0xDD]
        padded.trailingBytes = [0x01, 0x02, 0x03]
        let checksumAndTrailer = [UInt8](repeating: 0x7F, count: 8) + [0x07, 0x17, 0x20, 0x05, 0x00, 0x00, 0x00, 0x4B]
        let data = BinaryCookiesFixture.file(pages: [[padded, themeCookie]], trailer: checksumAndTrailer)

        let cookies = try parser.parse(data)

        #expect(cookies.map(\.name) == ["session", "theme"])
        #expect(cookies.first?.value == "abc123")
    }

    /// Rejects a file that is too short for a header.
    @Test func rejectsAFileThatIsTooShortForAHeader() {
        #expect(throws: SafariBinaryCookiesParser.ParseError.tooShort) {
            try parser.parse(Data("coo".utf8))
        }
    }

    /// Rejects a bad magic number.
    @Test func rejectsABadMagicNumber() {
        var bytes = [UInt8](BinaryCookiesFixture.file(pages: [[sessionCookie]]))
        bytes.replaceSubrange(0..<4, with: Array("kooc".utf8))

        #expect(throws: SafariBinaryCookiesParser.ParseError.invalidMagic) {
            try parser.parse(Data(bytes))
        }
    }

    /// Rejects a page count that overflows the file.
    @Test func rejectsAPageCountThatOverflowsTheFile() {
        let bytes: [UInt8] = Array("cook".utf8) + [0xFF, 0xFF, 0xFF, 0xFF]

        #expect(throws: SafariBinaryCookiesParser.ParseError.pageTableOutOfBounds(pageCount: 0xFFFF_FFFF)) {
            try parser.parse(Data(bytes))
        }
    }

    /// Rejects a truncated page.
    @Test func rejectsATruncatedPage() {
        let complete = [UInt8](BinaryCookiesFixture.file(pages: [[sessionCookie, themeCookie]]))
        let truncated = Array(complete.dropLast(20))

        #expect(throws: SafariBinaryCookiesParser.ParseError.pageOutOfBounds(pageIndex: 0)) {
            try parser.parse(Data(truncated))
        }
    }

    /// Rejects a cookie offset outside its page.
    @Test func rejectsACookieOffsetOutsideItsPage() {
        var bytes = [UInt8](BinaryCookiesFixture.file(pages: [[sessionCookie]]))
        // The single cookie offset lives at page start + 8; the page starts after
        // the 4-byte magic, the 4-byte page count and one 4-byte page size.
        let offsetIndex = 12 + 8
        bytes.replaceSubrange(offsetIndex..<offsetIndex + 4, with: BinaryCookiesFixture.littleEndian(UInt32(0xFFFF_FF00)))

        #expect(throws: SafariBinaryCookiesParser.ParseError.cookieOutOfBounds(pageIndex: 0, cookieIndex: 0)) {
            try parser.parse(Data(bytes))
        }
    }

    /// Rejects a cookie whose string offset leaves the record.
    @Test func rejectsACookieWhoseStringOffsetLeavesTheRecord() {
        var bytes = [UInt8](BinaryCookiesFixture.file(pages: [[sessionCookie]]))
        // First record begins at page start + 8 + 4 (one offset) + 4 (footer);
        // its name offset is the record's 20th byte.
        let recordStart = 12 + 16
        let nameOffsetIndex = recordStart + 20
        bytes.replaceSubrange(nameOffsetIndex..<nameOffsetIndex + 4, with: BinaryCookiesFixture.littleEndian(UInt32(0x7FFF_FFFF)))

        #expect(throws: SafariBinaryCookiesParser.ParseError.cookieOutOfBounds(pageIndex: 0, cookieIndex: 0)) {
            try parser.parse(Data(bytes))
        }
    }

    /// Rejects a value without a terminator.
    @Test func rejectsAValueWithoutATerminator() {
        var cookie = sessionCookie
        cookie.omitValueTerminator = true
        let data = BinaryCookiesFixture.file(pages: [[cookie]])

        #expect(throws: SafariBinaryCookiesParser.ParseError.cookieOutOfBounds(pageIndex: 0, cookieIndex: 0)) {
            try parser.parse(data)
        }
    }

    /// Bounds the bytes decoded from repeated record offsets.
    @Test func boundsTheBytesDecodedFromRepeatedRecordOffsets() throws {
        let page = BinaryCookiesFixture.pageRepeatingOneRecord(sessionCookie, times: 64)
        let data = BinaryCookiesFixture.file(encodedPages: [page])
        let recordSize = BinaryCookiesFixture.record(sessionCookie).count

        #expect(try parser.parse(data).count == 64)
        let bounded = SafariBinaryCookiesParser(maximumDecodedBytes: recordSize * 8)
        #expect(throws: SafariBinaryCookiesParser.ParseError.decodedSizeExceeded(limit: recordSize * 8)) {
            try bounded.parse(data)
        }
    }

    /// Applies the decode limit across the whole store, not per page.
    @Test func appliesTheDecodeLimitAcrossPagesNotPerPage() throws {
        let data = BinaryCookiesFixture.file(pages: [[sessionCookie], [sessionCookie]])
        let recordSize = BinaryCookiesFixture.record(sessionCookie).count
        let limit = recordSize + recordSize / 2
        let bounded = SafariBinaryCookiesParser(maximumDecodedBytes: limit)

        // Either page alone fits under the limit; together they do not.
        #expect(try bounded.parse(BinaryCookiesFixture.file(pages: [[sessionCookie]])).count == 1)
        #expect(throws: SafariBinaryCookiesParser.ParseError.decodedSizeExceeded(limit: limit)) {
            try bounded.parse(data)
        }
    }

    /// Rejects a string offset inside the fixed header.
    @Test func rejectsAStringOffsetInsideTheFixedHeader() {
        var bytes = [UInt8](BinaryCookiesFixture.file(pages: [[sessionCookie]]))
        let recordStart = 12 + 16
        let nameOffsetIndex = recordStart + 20
        bytes.replaceSubrange(nameOffsetIndex..<nameOffsetIndex + 4, with: BinaryCookiesFixture.littleEndian(UInt32(0)))

        #expect(throws: SafariBinaryCookiesParser.ParseError.cookieOutOfBounds(pageIndex: 0, cookieIndex: 0)) {
            try parser.parse(Data(bytes))
        }
    }

    /// An expired-only store decodes to cookies that are all expired.
    @Test func anExpiredOnlyStoreDecodesToCookiesThatAreAllExpired() throws {
        var expired = sessionCookie
        expired.expiry = 100
        var older = themeCookie
        older.expiry = -5
        let data = BinaryCookiesFixture.file(pages: [[expired, older]])
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let cookies = try parser.parse(data)

        #expect(cookies.count == 2)
        #expect(cookies.allSatisfy { $0.isExpired(at: now) })
    }

    /// A session or future cookie is not expired.
    @Test func aSessionOrFutureCookieIsNotExpired() throws {
        let data = BinaryCookiesFixture.file(pages: [[sessionCookie, themeCookie]])
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let cookies = try parser.parse(data)

        #expect(cookies.map { $0.isExpired(at: now) } == [false, false])
    }
}
