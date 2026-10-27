#if canImport(Compression)
import Compression
#endif
import Foundation
import SQLite3

/// Writers of the foreign formats the import reads, for valid seeds that the fuzz then damages. Each
/// follows the layout its reader's doc comment gives (SafariBinaryCookies, ChromiumSessionReader,
/// FirefoxSessionReader, ExportArchive), so a seed reads back as what it was built from.
struct ImportFuzzBytes {
    private(set) var bytes: [UInt8] = []

    mutating func le16(_ value: Int) {
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { bytes += $0 }
    }

    mutating func le32(_ value: Int) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { bytes += $0 }
    }

    mutating func be32(_ value: Int) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian) { bytes += $0 }
    }

    mutating func be64(_ value: Int) {
        withUnsafeBytes(of: UInt64(truncatingIfNeeded: value).bigEndian) { bytes += $0 }
    }

    mutating func le64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    mutating func append(_ more: some Sequence<UInt8>) {
        bytes += more
    }

    var data: Data { Data(bytes) }
}

/// Safari's `Cookies.binarycookies`: "cook", a big-endian page count and page sizes, then pages of
/// little-endian records whose strings follow a 56-byte header.
struct SafariCookieFixture {
    struct Cookie {
        var name: String
        var value: String
        var domain: String
        var path: String = "/"
        var flags: Int = 0
        /// Core Foundation absolute times.
        var expires: Double
        var created: Double = 700_000_000
    }

    static func record(_ cookie: Cookie) -> [UInt8] {
        var strings: [UInt8] = []
        var offsets: [Int] = []
        for text in [cookie.domain, cookie.name, cookie.path, cookie.value] {
            offsets.append(56 + strings.count)
            strings += Array(text.utf8) + [0]
        }
        var header = ImportFuzzBytes()
        header.le32(56 + strings.count)
        header.le32(0)
        header.le32(cookie.flags)
        header.le32(0)
        for offset in offsets { header.le32(offset) }
        header.le32(0)
        header.le32(0)
        header.le64(cookie.expires.bitPattern)
        header.le64(cookie.created.bitPattern)
        return header.bytes + strings
    }

    static func page(_ cookies: [Cookie]) -> [UInt8] {
        let records = cookies.map(record)
        var page = ImportFuzzBytes()
        page.append([0, 0, 1, 0])
        page.le32(records.count)
        var offset = 8 + 4 * records.count
        for record in records {
            page.le32(offset)
            offset += record.count
        }
        for record in records { page.append(record) }
        return page.bytes
    }

    static func file(_ pages: [[Cookie]]) -> Data {
        let encoded = pages.map(page)
        var file = ImportFuzzBytes()
        file.append(Array("cook".utf8))
        file.be32(encoded.count)
        for page in encoded { file.be32(page.count) }
        for page in encoded { file.append(page) }
        return file.data
    }

    static let sample = file([
        [Cookie(name: "sid", value: "abc", domain: ".example.com", flags: 5, expires: 2_000_000_000),
         Cookie(name: "old", value: "x", domain: "old.example", expires: 10)],
        [Cookie(name: "pref", value: "dark", domain: "news.example", path: "/a", expires: 1_900_000_000)],
    ])
}

/// A Chromium "SNSS" session command log: header, then uint16 size, uint8 id and payload per command.
struct ChromiumSessionFixture {
    struct Tab {
        var id: Int32
        var window: Int32
        var index: Int32
        var url: String
        var title: String
        var pinned = false
    }

    static func pickle(_ fields: (inout ImportFuzzBytes) -> Void) -> [UInt8] {
        var body = ImportFuzzBytes()
        fields(&body)
        var pickle = ImportFuzzBytes()
        pickle.le32(body.bytes.count)
        pickle.append(body.bytes)
        return pickle.bytes
    }

    static func string(_ text: String, into bytes: inout ImportFuzzBytes) {
        let utf8 = Array(text.utf8)
        bytes.le32(utf8.count)
        bytes.append(utf8 + [UInt8](repeating: 0, count: (4 - utf8.count % 4) % 4))
    }

    static func string16(_ text: String, into bytes: inout ImportFuzzBytes) {
        let units = Array(text.utf16)
        bytes.le32(units.count)
        for unit in units { bytes.le16(Int(unit)) }
        if units.count % 2 == 1 { bytes.le16(0) }
    }

    static func command(_ id: UInt8, _ payload: [UInt8], into file: inout ImportFuzzBytes) {
        file.le16(payload.count + 1)
        file.append([id])
        file.append(payload)
    }

    static func raw(_ values: Int32...) -> [UInt8] {
        var bytes = ImportFuzzBytes()
        for value in values { bytes.le32(Int(value)) }
        return bytes.bytes
    }

    static func file(_ tabs: [Tab], closedTab: Int32? = nil, closedWindow: Int32? = nil, version: Int = 3) -> Data {
        var file = ImportFuzzBytes()
        file.append(Array("SNSS".utf8))
        file.le32(version)
        for tab in tabs {
            command(0, raw(tab.window, tab.id), into: &file)
            command(2, raw(tab.id, tab.index), into: &file)
            command(6, pickle { body in
                body.le32(Int(tab.id))
                body.le32(0)
                string(tab.url, into: &body)
                string16(tab.title, into: &body)
            }, into: &file)
            command(7, raw(tab.id, 0), into: &file)
            if tab.pinned { command(12, raw(tab.id, 1), into: &file) }
        }
        if let closedTab { command(16, raw(closedTab, 0, 0), into: &file) }
        if let closedWindow { command(17, raw(closedWindow, 0, 0), into: &file) }
        return file.data
    }

    static let sample = file([
        Tab(id: 1, window: 1, index: 0, url: "https://example.com/", title: "Example", pinned: true),
        Tab(id: 2, window: 1, index: 1, url: "https://news.example/a?b=c", title: "Néws"),
        Tab(id: 3, window: 2, index: 0, url: "chrome://settings", title: "Settings"),
        Tab(id: 4, window: 3, index: 0, url: "https://closed.example/", title: "Closed"),
    ], closedTab: 9, closedWindow: 3)
}

/// mozLz4: the magic `mozLz40\0`, a little-endian uint32 decompressed size and one raw LZ4 block.
struct MozLz4Fixture {
    static func file(_ payload: Data) -> Data {
        let input = [UInt8](payload)
        var file = ImportFuzzBytes()
        file.append(Array("mozLz40\0".utf8))
        file.le32(input.count)
        file.append(block(input))
        return file.data
    }

    /// One LZ4 block of `input`: Compression's encoder (with matches) where there is one, else one sequence of
    /// literals only (the Linux tier), which every LZ4 decoder reads.
    static func block(_ input: [UInt8]) -> [UInt8] {
        #if canImport(Compression)
        var block = [UInt8](repeating: 0, count: input.count + 1024)
        let written = compression_encode_buffer(&block, block.count, input, input.count, nil, COMPRESSION_LZ4_RAW)
        return Array(block.prefix(written))
        #else
        return literalsOnly(input)
        #endif
    }

    /// The last-sequence form: a token whose high nibble is the literal count (15, then bytes of 255 and one
    /// smaller), then the literals.
    static func literalsOnly(_ input: [UInt8]) -> [UInt8] {
        guard input.count >= 15 else { return [UInt8(input.count) << 4] + input }
        var block: [UInt8] = [0xF0]
        var rest = input.count - 15
        while rest >= 255 {
            block.append(255)
            rest -= 255
        }
        return block + [UInt8(rest)] + input
    }

    static let sessionFile = file(session)

    static let session = Data(#"""
    {"windows":[{"tabs":[{"index":2,"pinned":true,"entries":[{"url":"https://a.example/","title":"A"},{"url":"https://b.example/","title":"B"}]},
    {"entries":[{"url":"about:blank"}]},{"index":0,"entries":[]}]},{"tabs":[{"index":1,"entries":[{"url":"file:///tmp/x.html","title":""}]}]}]}
    """#.utf8)

    static let searchEngines = Data(#"""
    {"version":10,"metaData":{"defaultEngineId":"a1"},"engines":[{"id":"google","_name":"Google"},
    {"id":"a1","_name":"Kagi","_definedAliases":["@kagi"],"_urls":[{"template":"https://kagi.com/search","params":[{"name":"q","value":"{searchTerms}"}]},
    {"type":"application/x-suggestions+json","template":"https://kagi.com/api/autosuggest?q={searchTerms}","params":[]}]}]}
    """#.utf8)
}

/// A zip of stored (method 0) entries: local headers, the central directory, the end record.
struct ZipFixture {
    static func file(_ entries: [(String, Data)]) -> Data {
        var zip = ImportFuzzBytes()
        var central = ImportFuzzBytes()
        for entry in entries {
            let name = Array(entry.0.utf8)
            let offset = zip.bytes.count
            zip.le32(0x0403_4B50)
            zip.le16(20)
            zip.le16(0)
            zip.le16(0)
            zip.le16(0)
            zip.le16(0)
            zip.le32(0)
            zip.le32(entry.1.count)
            zip.le32(entry.1.count)
            zip.le16(name.count)
            zip.le16(0)
            zip.append(name)
            zip.append(entry.1)
            central.le32(0x0201_4B50)
            central.le16(20)
            central.le16(20)
            central.le16(0)
            central.le16(0)
            central.le16(0)
            central.le16(0)
            central.le32(0)
            central.le32(entry.1.count)
            central.le32(entry.1.count)
            central.le16(name.count)
            central.le16(0)
            central.le16(0)
            central.le16(0)
            central.le16(0)
            central.le32(0)
            central.le32(offset)
            central.append(name)
        }
        let start = zip.bytes.count
        zip.append(central.bytes)
        zip.le32(0x0605_4B50)
        zip.le16(0)
        zip.le16(0)
        zip.le16(entries.count)
        zip.le16(entries.count)
        zip.le32(central.bytes.count)
        zip.le32(start)
        zip.le16(0)
        return zip.data
    }

    static let sample = file([
        ("Safari Export/Bookmarks.html", Data("<DL><DT><A HREF=\"https://example.com/\">Example</A></DL>".utf8)),
        ("Safari Export/History.json", ExportedHistoryFixture.safari),
        ("Safari Export/Passwords.csv", PasswordCSVFixture.sample),
        ("__MACOSX/._Passwords.csv", Data([0, 5, 22, 7])),
        ("Safari Export/Cards.csv", Data("number\n4111\n".utf8)),
    ])
}

/// A binary property list written object by object, so one object can be named from many parents (the
/// writer in Foundation never lets a test place references by hand).
struct BinaryPlistFixture {
    enum Object {
        case string(String)
        case array([Int])
        case dictionary([(Int, Int)])
    }

    static func file(_ objects: [Object], top: Int) -> Data {
        var body = ImportFuzzBytes()
        body.append(Array("bplist00".utf8))
        var offsets: [Int] = []
        func reference(_ index: Int) {
            body.append([UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF)])
        }
        func marker(_ high: UInt8, count: Int) {
            if count < 15 {
                body.append([high | UInt8(count)])
            } else {
                body.append([high | 0x0F, 0x11, UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
            }
        }
        for object in objects {
            offsets.append(body.bytes.count)
            switch object {
            case let .string(text):
                let ascii = Array(text.utf8)
                marker(0x50, count: ascii.count)
                body.append(ascii)
            case let .array(items):
                marker(0xA0, count: items.count)
                items.forEach(reference)
            case let .dictionary(pairs):
                marker(0xD0, count: pairs.count)
                pairs.map { $0.0 }.forEach(reference)
                pairs.map { $0.1 }.forEach(reference)
            }
        }
        let table = body.bytes.count
        for offset in offsets { body.be32(offset) }
        body.append([0, 0, 0, 0, 0, 0, 4, 2])
        body.be64(objects.count)
        body.be64(top)
        body.be64(table)
        return body.data
    }

    /// Safari bookmarks where each of `levels + 1` folders lists the folder below it twice: a file of a
    /// few hundred bytes that describes 2^(levels + 1) bookmarks.
    static func doublingBookmarks(levels: Int) -> Data {
        var objects: [Object] = [
            .string("Children"), .string("WebBookmarkType"), .string("WebBookmarkTypeList"), .string("Title"),
            .string("f"), .string("WebBookmarkTypeLeaf"), .string("URLString"), .string("https://example.com/"),
        ]
        objects.append(.dictionary([(1, 5), (6, 7)]))
        var below = objects.count - 1
        for _ in 0...levels {
            objects.append(.array([below, below]))
            objects.append(.dictionary([(1, 2), (3, 4), (0, objects.count - 1)]))
            below = objects.count - 1
        }
        objects.append(.array([below]))
        objects.append(.dictionary([(0, objects.count - 1)]))
        return file(objects, top: objects.count - 1)
    }
}

/// The JSON and CSV formats, as their readers' doc comments describe them.
struct ExportedHistoryFixture {
    static let safari = Data(#"""
    {"metadata":{"browser_name":"Safari"},"history":[{"url":"https://a.example/","title":"A","time_usec":1700000000000000,"visit_count":3},
    {"url":"https://a.example/","title":"A2","time_usec":1700000001000000,"visit_count":2},{"url":"javascript:alert(1)","time_usec":5}]}
    """#.utf8)

    static let takeout = Data(#"""
    {"Browser History":[{"url":"https://b.example/","title":"B","time_usec":1600000000000000},{"url":"https://b.example/","time_usec":1600000005000000}]}
    """#.utf8)
}

struct PasswordCSVFixture {
    static let sample = Data("""
    name,url,username,password,note\r
    Example,https://example.com/login?x=1,ann,"p,""w""d",\r
    Dup,https://example.com/,ann,other,\r
    Empty,https://empty.example/,bob,,\r
    App,android://abc@com.example,carl,secret,\r
    \r
    IDN,https://bücher.example:8443/,dee,pw\n
    """.utf8)
}

struct BookmarksFixture {
    static let chromium = Data(#"""
    {"checksum":"x","roots":{"bookmark_bar":{"name":"Bookmarks Bar","type":"folder","children":[
    {"type":"url","name":"Example","url":"https://example.com/","date_added":"13300000000000000"},
    {"type":"folder","name":"Work","children":[{"type":"url","name":"","url":"https://work.example/"},{"type":"url","url":"chrome://flags"}]}]},
    "other":{"children":[]},"synced":{"name":"","children":[{"type":"url","name":"S","url":"ftp://files.example/"}]}},"version":1}
    """#.utf8)

    static let arc = Data(#"""
    {"sidebar":{"containers":[{"global":{}},{"spaces":["s1",{"id":"s1","title":"Home","profile":{"default":true},
    "containerIDs":["unpinned","u1","pinned","p1"]}],"items":["p1",{"id":"p1","childrenIds":["t1","l1"]},
    "t1",{"id":"t1","title":"Arc","data":{"tab":{"savedURL":"https://arc.net/","savedTitle":"Arc"}},"createdAt":700000000},
    "l1",{"id":"l1","title":"List","data":{"list":{}},"childrenIds":["t2"]},
    "t2",{"id":"t2","data":{"tab":{"savedURL":"https://list.example/"}}},
    "f1",{"id":"f1","childrenIds":["t1"]}],"topAppsContainerIDs":[{"default":true},"f1"]}]}}
    """#.utf8)

    static let safariXML = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>Children</key><array>
    <dict><key>WebBookmarkType</key><string>WebBookmarkTypeProxy</string><key>Title</key><string>History</string></dict>
    <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>BookmarksBar</string><key>Children</key><array>
    <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>https://apple.com/</string>
    <key>URIDictionary</key><dict><key>title</key><string>Apple</string></dict></dict></array></dict>
    <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>com.apple.ReadingList</string><key>Children</key><array>
    <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string><key>URLString</key><string>https://read.example/</string></dict></array></dict>
    </array><key>WebBookmarkFileVersion</key><integer>1</integer></dict></plist>
    """#.utf8)

    static let safariBinary: Data = {
        guard let object = try? PropertyListSerialization.propertyList(from: safariXML, format: nil),
              let binary = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) else { return Data() }
        return binary
    }()
}

/// DER blobs of the shapes Firefox's key4.db and logins.json hold (FirefoxPasswordCrypto): the
/// structure is real, the ciphertext random, so a seed walks every field before it fails to open.
struct NSSFixture {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        if count < 0x80 { return [tag, UInt8(count)] + content }
        if count < 0x100 { return [tag, 0x81, UInt8(count)] + content }
        return [tag, 0x82, UInt8(count >> 8), UInt8(count & 0xFF)] + content
    }

    static func sequence(_ children: [UInt8]...) -> [UInt8] { tlv(0x30, children.flatMap { $0 }) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func integer(_ value: Int) -> [UInt8] {
        var content: [UInt8] = []
        var rest = value
        repeat {
            content.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        } while rest > 0
        if content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return tlv(0x02, content)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return tlv(0x06, []) }
        var content = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk = [UInt8(part & 0x7F)]
            var rest = part >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            content += chunk
        }
        return tlv(0x06, content)
    }

    /// A PBES2 (PBKDF2-HMAC-SHA256, AES-256-CBC) item with its 14-byte NSS IV.
    static let pbes2 = sequence(
        sequence(
            oid("1.2.840.113549.1.5.13"),
            sequence(
                sequence(oid("1.2.840.113549.1.5.12"),
                         sequence(octets([UInt8](repeating: 7, count: 32)), integer(1), integer(32),
                                  sequence(oid("1.2.840.113549.2.9")))),
                sequence(oid("2.16.840.1.101.3.4.1.42"), octets([UInt8](repeating: 3, count: 14))))),
        octets([UInt8](repeating: 0xA5, count: 32)))

    /// A pbeWithSha1AndTripleDES-CBC item.
    static let tripleDES = sequence(
        sequence(oid("1.2.840.113549.1.12.5.1.3"), sequence(octets([UInt8](repeating: 9, count: 20)), integer(1))),
        octets([UInt8](repeating: 0x5A, count: 24)))

    /// A logins.json value: {key id, {AES-256-CBC, IV}, ciphertext}.
    static let login = sequence(
        octets([UInt8](repeating: 0xF8, count: 16)),
        sequence(oid("2.16.840.1.101.3.4.1.42"), octets([UInt8](repeating: 1, count: 16))),
        octets([UInt8](repeating: 0x33, count: 32)))
}

/// SQLite files built with the C API (the same library the readers open them with).
struct SQLiteFixture {
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    static func create(_ file: URL, _ sql: String) throws {
        try? FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw Failed(description: "open \(file.path)") }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec"
            sqlite3_free(message)
            throw Failed(description: text)
        }
    }

    /// Single quotes doubled, for a literal in fixture SQL.
    static func quote(_ text: String) -> String { "'\(text.replacingOccurrences(of: "'", with: "''"))'" }

    /// A blob literal.
    static func blob(_ data: Data) -> String { "X'\(data.map { String(format: "%02X", $0) }.joined())'" }
}

/// Profile lists: Firefox's profiles.ini and Chromium's Local State.
struct ProfileListFixture {
    static let ini = Data("""
    [Install4F96D1932A9F858E]
    Default=Profiles/abc.default-release
    [Profile1]
    Name=dev
    IsRelative=1
    Path=Profiles/def.dev
    [Profile0]
    Name=default-release
    IsRelative=1
    Path=Profiles/abc.default-release
    Default=1
    [General]
    StartWithLastProfile=1
    """.utf8)

    static let folders = ["Default", "Profile 1", "Profile 9223372036854775807"]

    static let localState = Data(#"""
    {"profile":{"profiles_order":["Profile 1","Default"],"info_cache":{"Default":{"name":"Personal","profile_highlight_color":-2543579},
    "Profile 1":{"name":"Work","profile_color_seed":-15043608,"gaia_picture_file_name":"Google Profile Picture.png"},
    "Profile 9223372036854775807":{"name":"Big"}}}}
    """#.utf8)
}
