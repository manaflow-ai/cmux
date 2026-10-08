public import Foundation

/// Reads a password CSV the user exported from a browser or password manager
/// (Chrome, Edge, Safari, Firefox, 1Password, Bitwarden): a header row naming
/// the URL, username and password columns, then one sign-in per row (RFC 4180
/// quoting). Works on the bytes in place: each password goes from the file's
/// buffer straight into `SecretBytes` and is never a `String`; the caller
/// zeroes the buffer afterwards (plans/cmux-next/browser.md, "Browser import:
/// passwords and security").
public struct PasswordCSVReader: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// No header names a URL and a password column.
        case noPasswordColumns
    }

    static let urlColumns: Set<String> = ["url", "login_uri", "website", "web site", "login url"]
    /// In order of preference: a row whose username is empty uses the next
    /// one it has (Proton Pass exports both email and username).
    static let usernameColumns = ["username", "login_username", "user name", "user", "login", "email"]
    static let passwordColumns: Set<String> = ["password", "login_password"]

    public init() {}

    public func read(_ bytes: UnsafeRawBufferPointer) throws(Failure) -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        var records = Self.records(in: bytes)
        guard !records.isEmpty else { throw .noPasswordColumns }
        let header = records.removeFirst().map { Self.text($0, in: bytes).trimmingCharacters(in: .whitespaces).lowercased() }
        guard let urlColumn = header.firstIndex(where: Self.urlColumns.contains),
              let passwordColumn = header.firstIndex(where: Self.passwordColumns.contains) else { throw .noPasswordColumns }
        let usernameColumns = Self.usernameColumns.compactMap(header.firstIndex(of:))
        // Firefox lists HTTP authentication sign-ins with their realm; those are not web forms.
        let httpRealmColumn = header.firstIndex(of: "httprealm")

        var logins: [ImportedLogin] = []
        var skipped = LoginSkipCounts()
        var seen: Set<String> = []
        for record in records where !(record.count == 1 && record[0].isEmpty) {
            guard passwordColumn < record.count, !record[passwordColumn].isEmpty else {
                skipped.empty += 1
                continue
            }
            let password = Self.secret(record[passwordColumn], in: bytes)
            guard password.withUnsafeBytes { $0.isValidUTF8 } else {
                skipped.undecryptable += 1
                continue
            }
            let rawURL = urlColumn < record.count ? Self.text(record[urlColumn], in: bytes).trimmingCharacters(in: .whitespaces) : ""
            let httpRealm = httpRealmColumn.map { $0 < record.count && !record[$0].isEmpty } ?? false
            guard !httpRealm, let (url, realm) = Self.webForm(rawURL) else {
                skipped.notWebForm += 1
                continue
            }
            let username = usernameColumns.lazy.compactMap { $0 < record.count ? Self.text(record[$0], in: bytes) : nil }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            // The first row for a site and username wins, as the export lists it.
            guard seen.insert(realm + "\u{0}" + username).inserted else {
                skipped.duplicate += 1
                continue
            }
            logins.append(ImportedLogin(url: url, signonRealm: realm, username: username, password: password, created: nil))
        }
        return (logins, skipped)
    }

    /// The page URL (no user, password, query or fragment) and Chromium's
    /// match key ("https://example.com/", the host in ASCII, with a port only
    /// when it is not the scheme's own) for an http(s) sign-in.
    static func webForm(_ text: String) -> (url: String, realm: String)? {
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let encoded = components.encodedHost?.lowercased(), !encoded.isEmpty
        else { return nil }
        // IDN hosts as punycode, as Chromium keys them; IPv6 literals in brackets.
        let host = encoded.contains(":") && !encoded.hasPrefix("[") ? "[\(encoded)]" : encoded
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return (url.absoluteString, "\(scheme)://\(host)\(port)/")
    }

    // MARK: Fields

    /// One field's bytes; `escaped` when it holds doubled quotes to undo.
    struct Field {
        var range: Range<Int>
        var escaped: Bool
        var isEmpty: Bool { range.isEmpty }
    }

    /// Every record's fields. A UTF-8 byte order mark is skipped; CRLF and LF both end a record.
    static func records(in bytes: UnsafeRawBufferPointer) -> [[Field]] {
        var records: [[Field]] = []
        var fields: [Field] = []
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        while index < bytes.count {
            var field = Field(range: index..<index, escaped: false)
            if bytes[index] == quote {
                // A quoted field runs to the next lone quote.
                var end = index + 1
                while end < bytes.count {
                    if bytes[end] == quote {
                        if end + 1 < bytes.count, bytes[end + 1] == quote { field.escaped = true; end += 2; continue }
                        break
                    }
                    end += 1
                }
                field.range = (index + 1)..<min(end, bytes.count)
                index = end + 1
                // Anything between the closing quote and the separator is dropped.
                while index < bytes.count, bytes[index] != comma, bytes[index] != cr, bytes[index] != lf { index += 1 }
            } else {
                var end = index
                while end < bytes.count, bytes[end] != comma, bytes[end] != cr, bytes[end] != lf { end += 1 }
                field.range = index..<end
                index = end
            }
            fields.append(field)
            if index < bytes.count, bytes[index] == comma {
                index += 1
                if index == bytes.count { fields.append(Field(range: index..<index, escaped: false)) }
                continue
            }
            records.append(fields)
            fields = []
            if index < bytes.count, bytes[index] == cr { index += 1 }
            if index < bytes.count, bytes[index] == lf { index += 1 }
        }
        if !fields.isEmpty { records.append(fields) }
        return records
    }

    /// A field that is not secret, as text.
    static func text(_ field: Field, in bytes: UnsafeRawBufferPointer) -> String {
        let slice = UnsafeRawBufferPointer(rebasing: bytes[field.range])
        guard field.escaped else { return String(decoding: slice, as: UTF8.self) }
        return String(decoding: slice, as: UTF8.self).replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// The password field, copied (doubled quotes undone) into its own locked buffer.
    static func secret(_ field: Field, in bytes: UnsafeRawBufferPointer) -> SecretBytes {
        SecretBytes(capacity: field.range.count) { out in
            var written = 0
            var index = field.range.lowerBound
            while index < field.range.upperBound {
                out[written] = bytes[index]
                written += 1
                index += field.escaped && bytes[index] == UInt8(ascii: "\"") ? 2 : 1
            }
            return written
        }
    }
}
