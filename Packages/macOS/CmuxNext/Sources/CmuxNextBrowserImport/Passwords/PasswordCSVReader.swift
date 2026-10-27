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

    /// `columns`: the person's match for a header with no known names (the column sheet); nil
    /// reads the header's names.
    public func read(_ file: SecretBytes,
                     columns: PasswordCSVColumns? = nil) throws(Failure) -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        try file.withUnsafeBytes { (raw) throws(Failure) in
            // SAFETY: the view lives only for this closure, while `file` lends its bytes; what read
            // returns is copied out of it.
            try read(unsafe ByteView(raw), columns: columns)
        }
    }

    func read(_ bytes: ByteView,
              columns: PasswordCSVColumns?) throws(Failure) -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        var records = Self.records(in: bytes)
        guard !records.isEmpty else { throw .noPasswordColumns }
        let header = records.removeFirst().map { Self.text($0, in: bytes).trimmingCharacters(in: .whitespaces).lowercased() }
        let urlColumn: Int, passwordColumn: Int, usernameColumns: [Int]
        if let columns {
            guard columns.url != columns.password, header.indices.contains(columns.url), header.indices.contains(columns.password)
            else { throw .noPasswordColumns }
            urlColumn = columns.url
            passwordColumn = columns.password
            usernameColumns = columns.username.flatMap { $0 == passwordColumn || !header.indices.contains($0) ? nil : [$0] } ?? []
        } else {
            guard let url = header.firstIndex(where: Self.urlColumns.contains),
                  let password = header.firstIndex(where: Self.passwordColumns.contains) else { throw .noPasswordColumns }
            urlColumn = url
            passwordColumn = password
            usernameColumns = Self.usernameColumns.compactMap(header.firstIndex(of:))
        }
        // Firefox lists HTTP authentication sign-ins with their realm; those are not web forms.
        let httpRealmColumn = header.firstIndex(of: "httprealm")

        var logins: [ImportedLogin] = []
        var skipped = LoginSkipCounts()
        var seen: Set<String> = []
        for record in records where !(record.count == 1 && record[0].isEmpty) {
            guard let passwordField = record[checked: passwordColumn], !passwordField.isEmpty else {
                skipped.empty += 1
                continue
            }
            let password = Self.secret(passwordField, in: bytes)
            guard password.isValidUTF8 else {
                skipped.undecryptable += 1
                continue
            }
            let rawURL = record[checked: urlColumn].map { Self.text($0, in: bytes).trimmingCharacters(in: .whitespaces) } ?? ""
            let httpRealm = httpRealmColumn.flatMap { record[checked: $0] }.map { !$0.isEmpty } ?? false
            guard !httpRealm, let (url, realm) = Self.webForm(rawURL) else {
                skipped.notWebForm += 1
                continue
            }
            let username = usernameColumns.lazy.compactMap { record[checked: $0].map { Self.text($0, in: bytes) } }
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
    static func records(in bytes: ByteView) -> [[Field]] {
        var records: [[Field]] = []
        var fields: [Field] = []
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        while index < bytes.count {
            var field = Field(range: index..<index, escaped: false)
            if bytes.byte(index) == quote {
                // A quoted field runs to the next lone quote.
                var end = index + 1
                while end < bytes.count {
                    if bytes.byte(end) == quote {
                        if end + 1 < bytes.count, bytes.byte(end + 1) == quote { field.escaped = true; end += 2; continue }
                        break
                    }
                    end += 1
                }
                field.range = (index + 1)..<min(end, bytes.count)
                index = end + 1
                // Anything between the closing quote and the separator is dropped.
                while index < bytes.count, !Self.endsField(bytes.byte(index)) { index += 1 }
            } else {
                var end = index
                while end < bytes.count, !Self.endsField(bytes.byte(end)) { end += 1 }
                field.range = index..<end
                index = end
            }
            fields.append(field)
            if index < bytes.count, bytes.byte(index) == comma {
                index += 1
                if index == bytes.count { fields.append(Field(range: index..<index, escaped: false)) }
                continue
            }
            records.append(fields)
            fields = []
            if index < bytes.count, bytes.byte(index) == cr { index += 1 }
            if index < bytes.count, bytes.byte(index) == lf { index += 1 }
        }
        if !fields.isEmpty { records.append(fields) }
        return records
    }

    /// A comma, CR or LF: the byte after an unquoted field.
    private static func endsField(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ",") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }

    /// A field that is not secret, as text.
    static func text(_ field: Field, in bytes: ByteView) -> String {
        let text = bytes.view(field.range)?.text ?? ""
        guard field.escaped else { return text }
        return text.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// The password field, copied (doubled quotes undone) into its own locked buffer.
    static func secret(_ field: Field, in bytes: ByteView) -> SecretBytes {
        SecretBytes(capacity: field.range.count) { out in
            var written = 0
            var index = field.range.lowerBound
            while index < field.range.upperBound {
                // SAFETY: each pass writes one byte and moves `index` on by at least one, so
                // written < field.range.count <= out.count (the capacity asked for).
                let byte = bytes.byte(index)
                unsafe out[written] = byte
                written += 1
                index += field.escaped && byte == UInt8(ascii: "\"") ? 2 : 1
            }
            return written
        }
    }
}
