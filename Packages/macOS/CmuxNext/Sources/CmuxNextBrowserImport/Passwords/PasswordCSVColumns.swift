public import Foundation

/// The columns of a password CSV whose header names none that
/// ``PasswordCSVReader`` knows, as the person matched them in the column sheet
/// (indexes into the header row).
public struct PasswordCSVColumns: Equatable, Sendable {
    public var url: Int
    public var username: Int?
    public var password: Int

    public init(url: Int, username: Int?, password: Int) {
        self.url = url
        self.username = username
        self.password = password
    }
}

/// What the column sheet may show of a CSV it does not know: the header row's
/// names and how many rows follow, never a value. Nil when the first row may be
/// a sign-in rather than names: a field that looks like a website or an email
/// address, has no letter, or is long; or no data column holds a website
/// address at all (a file with no header row but a website column puts a
/// website in its first row). Such a row could hold a password, so cmux shows
/// none of it.
public struct PasswordCSVHeader: Equatable, Sendable {
    public let names: [String]
    public let rows: Int

    static let longestName = 40

    public static func read(_ file: SecretBytes) -> PasswordCSVHeader? {
        file.withUnsafeBytes { raw in
            // SAFETY: the view lives only for this closure, while `file` lends its bytes; the header
            // holds copied names only.
            read(unsafe ByteView(raw))
        }
    }

    static func read(_ bytes: ByteView) -> PasswordCSVHeader? {
        var records = PasswordCSVReader.records(in: bytes)
        guard !records.isEmpty else { return nil }
        let names = records.removeFirst().map { PasswordCSVReader.text($0, in: bytes).trimmingCharacters(in: .whitespaces) }
        guard names.count >= 2, !names.contains(where: looksLikeData) else { return nil }
        let rows = records.filter { !($0.count == 1 && $0[0].isEmpty) }
        // A website column in the data, whose header field is a name (checked above), not a website.
        // Checked on the bytes in place: a data field (maybe a password) never becomes a String.
        let websiteColumn = names.indices.contains { column in
            rows.contains { row in row[checked: column].flatMap { bytes.view($0.range) }.map { looksLikeWebsite($0) } ?? false }
        }
        guard websiteColumn else { return nil }
        return PasswordCSVHeader(names: names, rows: rows.count)
    }

    private static func looksLikeData(_ name: String) -> Bool {
        name.count > longestName || name.contains("@") || !name.contains(where: \.isLetter) || looksLikeWebsite(name)
    }

    /// "https://…", "www.…", or a dotted word with no space ("example.com").
    private static func looksLikeWebsite(_ text: String) -> Bool {
        looksLikeWebsite(Array(text.trimmingCharacters(in: .whitespaces).utf8))
    }

    /// Reads the field in place (no copy: it may be a password), from the front, with no index.
    private static func looksLikeWebsite<Bytes: BidirectionalCollection<UInt8>>(_ field: Bytes) -> Bool {
        let dot = UInt8(ascii: "."), space = UInt8(ascii: " "), colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/")
        let leading = field.drop(while: { $0 == space })
        guard let last = leading.lastIndex(where: { $0 != space }) else { return false }
        let value = leading.prefix(through: last)
        var hasDot = false, hasSpace = false
        for (offset, byte) in value.enumerated() {
            switch byte {
            case dot: hasDot = true
            case space: hasSpace = true
            case colon where value.dropFirst(offset + 1).starts(with: [slash, slash]): return true
            default: break
            }
        }
        let www: [UInt8] = Array("www.".utf8)
        if value.count >= 4, zip(value.prefix(4), www).allSatisfy({ $0 | 0x20 == $1 | 0x20 }) { return true }
        return hasDot && !hasSpace
    }
}
