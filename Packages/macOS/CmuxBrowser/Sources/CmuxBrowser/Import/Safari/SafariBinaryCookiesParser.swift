public import Foundation

/// Decodes Safari's `Cookies.binarycookies` store into ``SafariBinaryCookie`` records.
///
/// The format mixes endianness: the file header and page table are big-endian,
/// page and cookie records are little-endian. Expiries are IEEE-754 doubles in
/// Mac absolute time (seconds since 2001-01-01 UTC). The flags word carries
/// Secure (`0x1`), HttpOnly (`0x4`) and SameSite (`0x8` alone for Lax, `0x8`
/// with `0x10` for Strict); its other bits are ignored. Every read is bounds
/// checked, so a damaged or hostile file produces a ``ParseError`` instead of a
/// crash, and the bytes decoded from cookie records are capped so a page whose
/// offset table points at one record thousands of times cannot exhaust memory.
/// Bytes after the last page (Safari's checksum, trailer and policy plist) and
/// bytes inside a record that the fixed header does not address are ignored,
/// so newer Safari versions that append fields still decode.
///
/// Layout, with field offsets relative to the enclosing structure:
///
/// ```text
/// file:   "cook" | page count (BE u32) | page sizes (BE u32 each) | pages… | trailer
/// page:   00 00 01 00 | cookie count (LE u32) | cookie offsets (LE u32 each) | 00 00 00 00 | cookies…
/// cookie: size | version | flags | has port | url off | name off | path off | value off
///         | comment off | comment URL off | expiry (LE f64) | creation (LE f64) | strings…
/// ```
public struct SafariBinaryCookiesParser: Sendable {
    /// Why a store could not be decoded. Indices name the structure at fault so a
    /// caller can log them; they are not shown to users.
    public enum ParseError: Error, Equatable {
        /// Fewer than eight bytes, so there is no magic number and page count.
        case tooShort
        /// The file does not start with `cook`.
        case invalidMagic
        /// The page count needs a larger page table than the file holds.
        case pageTableOutOfBounds(pageCount: Int)
        /// A page's declared size runs past the end of the file.
        case pageOutOfBounds(pageIndex: Int)
        /// A page is too small for its header or claims more cookies than fit.
        case invalidPageHeader(pageIndex: Int)
        /// A cookie record, or one of its string offsets, leaves its page or
        /// record, or a string has no null terminator inside the record.
        case cookieOutOfBounds(pageIndex: Int, cookieIndex: Int)
        /// Decoding the records would exceed the parser's byte limit.
        case decodedSizeExceeded(limit: Int)
    }

    private static let magic: [UInt8] = Array("cook".utf8)
    private static let pageHeader: [UInt8] = [0x00, 0x00, 0x01, 0x00]
    private static let cookieFixedHeaderSize = 56
    private static let secureFlag: UInt32 = 0x1
    private static let httpOnlyFlag: UInt32 = 0x4
    private static let sameSiteMask: UInt32 = 0x18
    private static let sameSiteLaxFlags: UInt32 = 0x08
    private static let sameSiteStrictFlags: UInt32 = 0x18

    /// Upper bound on the record bytes one `parse` call decodes.
    ///
    /// Record sizes are summed as records are visited, so an offset table that
    /// names the same record many times counts it each time.
    public let maximumDecodedBytes: Int

    /// Creates a parser. It holds no mutable state, so one instance can decode many stores.
    ///
    /// - Parameter maximumDecodedBytes: Record bytes a single store may decode
    ///   before ``ParseError/decodedSizeExceeded(limit:)`` is thrown. The default
    ///   of 64 MiB is far above any real Safari store, which is a few megabytes.
    public init(maximumDecodedBytes: Int = 64 << 20) {
        self.maximumDecodedBytes = maximumDecodedBytes
    }

    /// Decodes a whole `Cookies.binarycookies` file.
    ///
    /// - Parameter data: The file's bytes.
    /// - Returns: Every cookie in page order. Cookies with an empty name are
    ///   returned as stored; the caller decides whether to keep them.
    /// - Throws: ``ParseError`` when the file's structure is inconsistent or
    ///   decoding would exceed ``maximumDecodedBytes``.
    public func parse(_ data: Data) throws -> [SafariBinaryCookie] {
        let file = ByteReader(bytes: [UInt8](data))
        guard file.count >= 8 else { throw ParseError.tooShort }
        guard file.bytes(at: 0, count: 4) == Self.magic else { throw ParseError.invalidMagic }

        let pageCount = Int(file.bigEndianUInt32(at: 4) ?? 0)
        guard pageCount <= (file.count - 8) / 4 else {
            throw ParseError.pageTableOutOfBounds(pageCount: pageCount)
        }

        var cookies: [SafariBinaryCookie] = []
        var decodedBytes = 0
        var pageStart = 8 + pageCount * 4
        for pageIndex in 0..<pageCount {
            let pageSize = Int(file.bigEndianUInt32(at: 8 + pageIndex * 4) ?? 0)
            guard pageSize <= file.count - pageStart else {
                throw ParseError.pageOutOfBounds(pageIndex: pageIndex)
            }
            let page = file.slice(at: pageStart, count: pageSize)
            cookies.append(contentsOf: try parsePage(page, pageIndex: pageIndex, decodedBytes: &decodedBytes))
            pageStart += pageSize
        }
        return cookies
    }

    /// Decodes one page's cookies, adding the record bytes it reads to `decodedBytes` so the limit spans the whole store.
    private func parsePage(_ page: ByteReader, pageIndex: Int, decodedBytes: inout Int) throws -> [SafariBinaryCookie] {
        // Header, cookie count and footer are the minimum a page carries.
        guard page.count >= 12, page.bytes(at: 0, count: 4) == Self.pageHeader else {
            throw ParseError.invalidPageHeader(pageIndex: pageIndex)
        }
        let cookieCount = Int(page.littleEndianUInt32(at: 4) ?? 0)
        guard cookieCount <= (page.count - 12) / 4 else {
            throw ParseError.invalidPageHeader(pageIndex: pageIndex)
        }

        // No capacity is reserved from `cookieCount`: it comes from the file, and
        // the result grows only with records that pass the decode budget.
        var cookies: [SafariBinaryCookie] = []
        for cookieIndex in 0..<cookieCount {
            let offset = Int(page.littleEndianUInt32(at: 8 + cookieIndex * 4) ?? 0)
            guard offset <= page.count - Self.cookieFixedHeaderSize,
                  let size = page.littleEndianUInt32(at: offset).map(Int.init),
                  size >= Self.cookieFixedHeaderSize,
                  size <= page.count - offset else {
                throw ParseError.cookieOutOfBounds(pageIndex: pageIndex, cookieIndex: cookieIndex)
            }
            guard size <= maximumDecodedBytes - decodedBytes else {
                throw ParseError.decodedSizeExceeded(limit: maximumDecodedBytes)
            }
            decodedBytes += size
            guard let cookie = parseCookie(page.slice(at: offset, count: size)) else {
                throw ParseError.cookieOutOfBounds(pageIndex: pageIndex, cookieIndex: cookieIndex)
            }
            cookies.append(cookie)
        }
        return cookies
    }

    /// Decodes one record whose size has already been checked against its page.
    /// Returns `nil` when a string offset points into the fixed header or outside
    /// the record, or a string runs to the end of the record without a terminator.
    ///
    /// A zero or non-finite expiry means a session cookie. A negative expiry is
    /// a real date before 2001 and is kept, so the caller can see the cookie has
    /// already expired instead of treating it as a session cookie.
    private func parseCookie(_ record: ByteReader) -> SafariBinaryCookie? {
        guard let flags = record.littleEndianUInt32(at: 8),
              let domain = record.cString(atOffsetStoredAt: 16),
              let name = record.cString(atOffsetStoredAt: 20),
              let path = record.cString(atOffsetStoredAt: 24),
              let value = record.cString(atOffsetStoredAt: 28),
              let expiry = record.littleEndianDouble(at: 40) else {
            return nil
        }

        let expiresDate: Date? = (expiry.isFinite && expiry != 0)
            ? Date(timeIntervalSinceReferenceDate: expiry)
            : nil

        return SafariBinaryCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expiresDate: expiresDate,
            isSecure: flags & Self.secureFlag != 0,
            isHTTPOnly: flags & Self.httpOnlyFlag != 0,
            sameSite: Self.sameSite(fromFlags: flags)
        )
    }

    /// The SameSite policy in a record's flags word. `HTTPCookieStorage` writes
    /// `0x08` for Lax and `0x18` for Strict; a cookie with no policy has `0x10`
    /// alone or neither bit, and both decode to `nil`.
    private static func sameSite(fromFlags flags: UInt32) -> SafariBinaryCookie.SameSite? {
        switch flags & sameSiteMask {
        case sameSiteLaxFlags: .lax
        case sameSiteStrictFlags: .strict
        default: nil
        }
    }

    /// Bounds-checked reads over a byte window. Every accessor returns `nil`
    /// instead of trapping when the request leaves the window.
    private struct ByteReader {
        private let storage: [UInt8]
        private let start: Int
        let count: Int

        /// A window over all of `bytes`.
        init(bytes: [UInt8]) {
            storage = bytes
            start = 0
            count = bytes.count
        }

        /// A window of `count` bytes starting at `start` in `storage`.
        private init(storage: [UInt8], start: Int, count: Int) {
            self.storage = storage
            self.start = start
            self.count = count
        }

        /// A sub-window; the caller has already checked `offset + count <= self.count`.
        func slice(at offset: Int, count: Int) -> ByteReader {
            ByteReader(storage: storage, start: start + offset, count: count)
        }

        /// The `count` bytes at `offset`, or `nil` when they leave the window.
        func bytes(at offset: Int, count: Int) -> [UInt8]? {
            guard offset >= 0, count >= 0, offset <= self.count - count else { return nil }
            return Array(storage[(start + offset)..<(start + offset + count)])
        }

        /// The big-endian `UInt32` at `offset`, or `nil` when it leaves the window.
        func bigEndianUInt32(at offset: Int) -> UInt32? {
            bytes(at: offset, count: 4).map { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        }

        /// The little-endian `UInt32` at `offset`, or `nil` when it leaves the window.
        func littleEndianUInt32(at offset: Int) -> UInt32? {
            bytes(at: offset, count: 4).map { $0.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        }

        /// The little-endian `Double` at `offset`, or `nil` when it leaves the window.
        func littleEndianDouble(at offset: Int) -> Double? {
            bytes(at: offset, count: 8).map { raw in
                Double(bitPattern: raw.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            }
        }

        /// Reads the little-endian offset stored at `offsetField`, then the
        /// null-terminated string it points at. Strings start after the fixed
        /// cookie header, so an offset inside it is a damaged record and yields
        /// `nil`, as does a string with no terminator before the window ends;
        /// invalid UTF-8 is replaced rather than rejected.
        func cString(atOffsetStoredAt offsetField: Int) -> String? {
            guard let stringOffset = littleEndianUInt32(at: offsetField).map(Int.init),
                  stringOffset >= SafariBinaryCookiesParser.cookieFixedHeaderSize,
                  stringOffset < count else {
                return nil
            }
            let begin = start + stringOffset
            let end = start + count
            guard let terminator = storage[begin..<end].firstIndex(of: 0) else { return nil }
            return String(decoding: storage[begin..<terminator], as: UTF8.self)
        }
    }
}
