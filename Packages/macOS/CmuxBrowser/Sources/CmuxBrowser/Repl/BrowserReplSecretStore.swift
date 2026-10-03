import CryptoKit
public import Foundation

/// The session's named secrets (docs/browser-repl/reference-c-parity.md#secrets).
///
/// Values live here, in the native session, and never cross into the REPL's
/// JavaScript: the runtime holds names only, the session substitutes a value
/// into `input.insertText` for the driver, which types it only into a frame
/// whose origin matches the secret's domains, and every string the session
/// hands back to JavaScript or prints (driver results, events, fetch
/// responses, output, errors, written text files) is masked as
/// `<secret:name>`, including the value's percent-encoded, JSON-escaped,
/// HTML-escaped and Base64-wrapped forms (a Basic `Authorization` header).
///
/// A TOTP secret's value is its seed. The codes it generates are secrets too
/// while a server can still accept them: the code of the current 30-second
/// window and of the windows on each side (the clock skew RFC 6238 servers
/// allow, so the code typed now stays covered until it expires) are masked as
/// `<secret:name>` wherever they stand as a whole number, and are capture
/// masks for the secret's domains.
public final class BrowserReplSecretStore: @unchecked Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let value: String
        public let domains: [BrowserReplDomainPattern]
        public let totp: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var matchers: [Matcher] = []
    private var totpKeys: [(name: String, key: Data, domains: [BrowserReplDomainPattern])] = []
    private var codeCache: (window: Int64, codes: [ValidCodes])?

    public init() {}

    public var isEmpty: Bool { lock.withLock { entries.isEmpty } }

    /// Registers `name`. A secret needs at least one domain; a TOTP secret
    /// must be base32.
    public func set(name: String, value: String, domains rawDomains: [String], totp: Bool, title: String) throws {
        guard name.range(of: "^[\\w.-]{1,64}$", options: .regularExpression) != nil else {
            throw invalid("\(title): name: expected letters, digits, _, . or - (at most 64), got \(Self.quote(name))")
        }
        guard !value.isEmpty else { throw invalid("\(title): \(name): value: expected a non-empty string") }
        guard !rawDomains.isEmpty else {
            throw invalid("\(title): \(name): domains: expected the domains it may be typed into, such as [\"example.com\"]; a secret without domains is not accepted")
        }
        let domains = try rawDomains.map { try BrowserReplDomainPattern.parse($0, title: title) }
        let isTOTP = totp || name.hasSuffix("bu_2fa_code")
        if isTOTP, Self.base32Decode(value) == nil { throw invalid("secrets: a TOTP secret must be base32") }
        lock.withLock {
            if entries[name] == nil { order.append(name) }
            entries[name] = Entry(name: name, value: value, domains: domains, totp: isTOTP)
            rebuildLocked()
        }
    }

    /// Loads reference C's `sensitive_data` shape:
    /// `{ "<domain pattern>": { name: value | { value, totp } } }`.
    /// A name repeated with the same value under several patterns gets every pattern.
    /// - Returns: The names loaded, in order.
    public func load(_ object: Any) throws -> [String] {
        guard let groups = object as? [String: Any] else {
            throw invalid("secrets.load: expected { \"<domain pattern>\": { name: value } }")
        }
        var names: [String] = []
        for (pattern, rawEntries) in groups.sorted(by: { $0.key < $1.key }) {
            guard let group = rawEntries as? [String: Any] else {
                throw invalid("secrets.load: \(Self.quote(pattern)): a secret needs domains; expected { \"<domain pattern>\": { name: value } }")
            }
            for (name, raw) in group.sorted(by: { $0.key < $1.key }) {
                let object = raw as? [String: Any]
                guard let value = (object?["value"] ?? raw) as? String else {
                    throw invalid("secrets.load: \(name): value: expected a non-empty string")
                }
                let prior = lock.withLock { entries[name] }
                let domains = prior.map { $0.value == value ? $0.domains.map(\.raw) + [pattern] : [pattern] } ?? [pattern]
                let totp = (object?["totp"] as? Bool ?? false) || (prior?.totp ?? false)
                try set(name: name, value: value, domains: domains, totp: totp, title: "secrets.load")
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    @discardableResult
    public func delete(_ name: String) -> Bool {
        lock.withLock {
            guard entries.removeValue(forKey: name) != nil else { return false }
            order.removeAll { $0 == name }
            rebuildLocked()
            return true
        }
    }

    public func clear() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
            rebuildLocked()
        }
    }

    public func has(_ name: String) -> Bool { lock.withLock { entries[name] != nil } }

    /// `[{ name, domains, totp }]` in registration order; never values.
    public func describe(_ names: [String]? = nil) -> [[String: Any]] {
        lock.withLock {
            (names ?? order).compactMap { name in
                guard let entry = entries[name] else { return nil }
                return ["name": name, "domains": entry.domains.map(\.raw), "totp": entry.totp]
            }
        }
    }

    /// The text to type for `name` now (the current code of a TOTP secret)
    /// and the domains it may be typed into.
    public func valueToType(_ name: String, at date: Date = Date()) -> (text: String, domains: [BrowserReplDomainPattern])? {
        guard let entry = lock.withLock({ entries[name] }) else { return nil }
        if entry.totp {
            guard let key = Self.base32Decode(entry.value) else { return nil }
            return (Self.totp(key: key, time: date.timeIntervalSince1970), entry.domains)
        }
        return (entry.value, entry.domains)
    }

    /// Plain values, and the TOTP codes that are valid now, with their
    /// domains, for masking captures.
    public var captureMasks: [(value: String, domains: [BrowserReplDomainPattern])] {
        captureMasks(at: Date())
    }

    func captureMasks(at date: Date) -> [(value: String, domains: [BrowserReplDomainPattern])] {
        let plain = lock.withLock { order.compactMap { entries[$0] }.filter { !$0.totp }.map { ($0.value, $0.domains) } }
        return plain + validCodes(at: date).flatMap { entry in entry.codes.map { ($0, entry.domains) } }
    }

    /// Windows on each side of the current one whose codes a server still
    /// accepts (RFC 6238's recommended skew of one step).
    static let totpSkewWindows = 1

    private struct ValidCodes {
        let mask: String
        let codes: [String]
        let domains: [BrowserReplDomainPattern]
        /// Matches one of `codes` standing as a whole number.
        let pattern: NSRegularExpression?
    }

    /// The codes of every TOTP secret a server can still accept at `date`,
    /// computed once per window.
    private func validCodes(at date: Date) -> [ValidCodes] {
        let window = Int64(floor(date.timeIntervalSince1970 / Self.totpPeriod))
        return lock.withLock {
            guard !totpKeys.isEmpty else { return [] }
            if let cached = codeCache, cached.window == window { return cached.codes }
            let codes = totpKeys.map { entry in
                let list = Array(Set((-Self.totpSkewWindows...Self.totpSkewWindows).map {
                    Self.totp(key: entry.key, time: Double(window + Int64($0)) * Self.totpPeriod)
                })).sorted()
                return ValidCodes(
                    mask: "<secret:\(entry.name)>",
                    codes: list,
                    domains: entry.domains,
                    pattern: try? NSRegularExpression(pattern: "(?<![0-9])(?:" + list.joined(separator: "|") + ")(?![0-9])")
                )
            }
            codeCache = (window, codes)
            return codes
        }
    }

    // MARK: Redaction

    private struct Matcher {
        let mask: String
        let bytes: Data
        let literals: [String]
        let encoded: NSRegularExpression?
    }

    private static let base64Token = try! NSRegularExpression(pattern: "[A-Za-z0-9+/_-]{8,}={0,2}")

    private func rebuildLocked() {
        codeCache = nil
        totpKeys = order.compactMap { entries[$0] }.filter(\.totp).compactMap { entry in
            Self.base32Decode(entry.value).map { (entry.name, $0, entry.domains) }
        }
        matchers = order.compactMap { entries[$0] }
            .sorted { $0.value.count > $1.value.count }
            .map { entry in
                let value = entry.value
                let json = (JSONSerialization.browserReplString(value) ?? "\"\"").dropFirst().dropLast()
                let html = value.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                let htmlApostrophe = html.replacingOccurrences(of: "'", with: "&#39;")
                let htmlHexApostrophe = html.replacingOccurrences(of: "'", with: "&#x27;")
                let literals = Array(Set([value, String(json), html, htmlApostrophe, htmlHexApostrophe]))
                    .filter { !$0.isEmpty }
                    .sorted { $0.count > $1.count }
                return Matcher(
                    mask: "<secret:\(entry.name)>",
                    bytes: Data(value.utf8),
                    literals: literals,
                    encoded: Self.percentEncodedPattern(value)
                )
            }
    }

    /// A pattern that matches `value` with any of its characters written
    /// literally or percent-encoded (either hex case), and a space also as `+`.
    private static func percentEncodedPattern(_ value: String) -> NSRegularExpression? {
        var pattern = ""
        for character in value {
            let bytes = Array(String(character).utf8)
            let encoded = bytes.map { byte -> String in
                let hex = String(format: "%02X", byte)
                return "%" + hex.map { $0.isLetter ? "[\($0)\(Character($0.lowercased()))]" : String($0) }.joined()
            }.joined()
            var options = [NSRegularExpression.escapedPattern(for: String(character)), encoded]
            if character == " " { options.append("\\+") }
            pattern += "(?:" + options.joined(separator: "|") + ")"
        }
        return try? NSRegularExpression(pattern: pattern)
    }

    /// `text` with every registered value and its encodings masked, and the
    /// TOTP codes valid now.
    public func redact(_ text: String) -> String {
        redact(text, at: Date())
    }

    func redact(_ text: String, at date: Date) -> String {
        let matchers = lock.withLock { self.matchers }
        guard !matchers.isEmpty, !text.isEmpty else { return text }
        var out = Self.redactBase64(text, matchers)
        for matcher in matchers {
            for literal in matcher.literals where out.contains(literal) {
                out = out.replacingOccurrences(of: literal, with: matcher.mask)
            }
            if let encoded = matcher.encoded, out.contains("%") || out.contains("+") {
                let range = NSRange(out.startIndex..., in: out)
                out = encoded.stringByReplacingMatches(in: out, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: matcher.mask))
            }
        }
        return redactCodes(out, at: date)
    }

    /// Masks the valid TOTP codes where they stand as a whole number (a code
    /// inside a longer run of digits is another number).
    private func redactCodes(_ text: String, at date: Date) -> String {
        guard text.utf8.contains(where: { (0x30...0x39).contains($0) }) else { return text }
        var out = text
        for entry in validCodes(at: date) {
            guard let pattern = entry.pattern else { continue }
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.mask)
            )
        }
        return out
    }

    /// Masks Base64 tokens whose decoded bytes hold a value.
    private static func redactBase64(_ text: String, _ matchers: [Matcher]) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let tokens = base64Token.matches(in: text, range: range)
        guard !tokens.isEmpty else { return text }
        var out = text
        for token in tokens.reversed() {
            guard let tokenRange = Range(token.range, in: out) else { continue }
            var encoded = String(out[tokenRange]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "="))
            while encoded.count % 4 != 0 { encoded += "=" }
            guard let decoded = Data(base64Encoded: encoded),
                  let hit = matchers.first(where: { decoded.range(of: $0.bytes) != nil }) else { continue }
            out.replaceSubrange(tokenRange, with: hit.mask)
        }
        return out
    }

    /// A JSON document with every string (keys too) redacted. Text that is
    /// not JSON is redacted as text.
    public func redactJSON(_ json: String) -> String {
        guard !isEmpty else { return json }
        guard let value = JSONSerialization.browserReplValue(json) else { return redact(json) }
        return JSONSerialization.browserReplString(redactValue(value)) ?? redact(json)
    }

    /// `value` (decoded JSON) with every string redacted.
    public func redactValue(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return redact(text)
        case let list as [Any]:
            return list.map(redactValue)
        case let object as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in object { out[redact(key)] = redactValue(item) }
            return out
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            // A page can read a code as a number (`Number(field.value)`),
            // which drops a leading zero.
            var forms = [number.stringValue]
            let integer = number.int64Value
            if Double(integer) == number.doubleValue, (0..<1_000_000).contains(integer) {
                forms.append(String(format: "%06lld", integer))
            }
            for form in forms {
                let masked = redact(form)
                if masked != form { return masked }
            }
            return value
        default:
            return value
        }
    }

    // MARK: TOTP (RFC 6238)

    static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = Data()
        var buffer = 0
        var bits = 0
        for character in text.uppercased() where !" =-\t\n".contains(character) {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        return out
    }

    static let totpPeriod: Double = 30

    static func totp(key: Data, time: TimeInterval, digits: Int = 6, period: Double = totpPeriod) -> String {
        var counter = UInt64(max(0, floor(time / period))).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(mac[19] & 0x0f)
        let code = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let text = String(code % modulus)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    private func invalid(_ message: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "invalid", message: message)
    }

    private static func quote(_ text: String) -> String {
        JSONSerialization.browserReplString(text) ?? text
    }
}
