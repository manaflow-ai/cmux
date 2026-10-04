import CryptoKit
public import Foundation

/// The session's named secrets (docs/browser-repl/reference-c-parity.md#secrets).
///
/// Values live here, in the native session, and never cross into the REPL's
/// JavaScript: the runtime holds names only, the session substitutes a value
/// into `input.insertText` for the driver, which types it only into a frame
/// whose origin matches the secret's domains, and every string the session
/// hands back to JavaScript or prints (driver results, events, fetch
/// responses, output, errors, files written and read back) is masked as
/// `<secret:name>`, including the value's percent-encoded (also twice),
/// JSON- and JavaScript-escaped, HTML-escaped (named and numeric
/// references), character by character in any mix, and Base64-wrapped
/// forms (a Basic `Authorization` header,
/// Base64 at any offset in a longer run; see
/// ``BrowserReplSecretScanner/minimumBytesAtEveryOffset`` for short
/// values). A value transformed otherwise (compressed, hex, Base64 twice or
/// broken across lines) is not found.
/// Masking is one linear pass (``BrowserReplSecretScanner``) whose growth
/// is bounded: text that masking would grow by more than
/// ``maximumGrowth`` is withheld, and bytes are refused.
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
        /// The name shown in its mask, `<secret:maskName>`: `name`, except
        /// for a typed value registered under an internal key.
        let maskName: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var values: [BrowserReplSecretScanner.Value] = []
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
            entries[name] = Entry(name: name, value: value, domains: domains, totp: isTOTP, maskName: name)
            rebuildLocked()
        }
    }

    /// Registers `value` as a literal under the internal `key`, masked as
    /// `<secret:maskName>`. For values another session typed
    /// (``BrowserReplTypedSecrets``): the value is the text the field holds
    /// (a TOTP secret's code, not its seed), so no TOTP rule applies, and
    /// `key` keeps values that share a name apart.
    func setLiteral(key: String, maskName: String, value: String, domains: [BrowserReplDomainPattern]) {
        guard !value.isEmpty else { return }
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = Entry(name: key, value: value, domains: domains, totp: false, maskName: maskName)
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
                return ValidCodes(mask: "<secret:\(entry.name)>", codes: list, domains: entry.domains)
            }
            codeCache = (window, codes)
            return codes
        }
    }

    // MARK: Redaction

    /// How many bytes masking may add to one text, byte buffer or JSON
    /// value. A mask is longer than a short value, so a body full of a
    /// one-character secret would otherwise grow up to 73 times.
    public static let maximumGrowth = 8 << 20

    private func rebuildLocked() {
        codeCache = nil
        totpKeys = order.compactMap { entries[$0] }.filter(\.totp).compactMap { entry in
            Self.base32Decode(entry.value).map { (entry.maskName, $0, entry.domains) }
        }
        values = order.compactMap { entries[$0] }
            .sorted { $0.value.utf8.count > $1.value.utf8.count }
            .map { BrowserReplSecretScanner.Value(value: $0.value, mask: "<secret:\($0.maskName)>") }
    }

    /// The scanner for the values registered now and the TOTP codes valid
    /// at `date`.
    private func scanner(at date: Date) -> BrowserReplSecretScanner? {
        let values = lock.withLock { self.values }
        guard !values.isEmpty else { return nil }
        let codes = validCodes(at: date).flatMap { entry in
            entry.codes.map { (digits: Array($0.utf8), mask: Array(entry.mask.utf8)) }
        }
        return BrowserReplSecretScanner(values: values, codes: codes)
    }

    /// Why masking withheld `count` bytes.
    static func limitMessage(_ count: Int) -> String {
        "masking secrets would grow these \(count) bytes by more than the redaction limit of \(maximumGrowth >> 20) MiB, so they are withheld"
    }

    /// `text` with every registered value and its encodings masked, and the
    /// TOTP codes valid now. Text that masking would grow by more than
    /// ``maximumGrowth`` is replaced by a note saying it was withheld.
    public func redact(_ text: String) -> String {
        redact(text, at: Date())
    }

    func redact(_ text: String, at date: Date) -> String {
        var budget = Self.maximumGrowth
        return (try? redact(text, at: date, budget: &budget)) ?? "<\(Self.limitMessage(text.utf8.count))>"
    }

    private func redact(_ text: String, at date: Date, budget: inout Int) throws -> String {
        guard !text.isEmpty, let scanner = scanner(at: date) else { return text }
        var text = text
        let outcome = text.withUTF8 { scanner.redact($0, budget: &budget) }
        switch outcome {
        case .unchanged: return text
        case .redacted(let bytes): return String(decoding: bytes, as: UTF8.self)
        case .overLimit: throw BrowserReplDriverError(code: "invalid", message: Self.limitMessage(text.utf8.count))
        }
    }

    /// `data` with every registered value and its encodings masked, text or
    /// binary alike: the value's UTF-8 bytes and their encoded forms are
    /// matched byte by byte. A value the bytes hold only compressed or in
    /// another encoding is not found.
    /// - Throws: `invalid` when masking would grow the bytes by more than
    ///   ``maximumGrowth``.
    public func redact(_ data: Data) throws -> Data {
        guard !data.isEmpty, let scanner = scanner(at: Date()) else { return data }
        var budget = Self.maximumGrowth
        let outcome = data.withUnsafeBytes { scanner.redact($0.bindMemory(to: UInt8.self), budget: &budget) }
        switch outcome {
        case .unchanged: return data
        case .redacted(let bytes): return Data(bytes)
        case .overLimit: throw BrowserReplDriverError(code: "invalid", message: Self.limitMessage(data.count))
        }
    }

    /// A JSON document with every string (keys too) redacted. Text that is
    /// not JSON is redacted as text.
    public func redactJSON(_ json: String) -> String {
        guard !isEmpty else { return json }
        guard let value = JSONSerialization.browserReplValue(json) else { return redact(json) }
        return JSONSerialization.browserReplString(redactValue(value)) ?? redact(json)
    }

    /// `value` (decoded JSON) with every string redacted. A value that
    /// masking would grow by more than ``maximumGrowth`` in all is replaced
    /// by a note saying it was withheld.
    public func redactValue(_ value: Any) -> Any {
        (try? redactedValue(value)) ?? "<\(Self.limitMessage(JSONSerialization.browserReplString(value)?.utf8.count ?? 0))>"
    }

    /// `value` (decoded JSON) with every string redacted.
    /// - Throws: `invalid` when masking would grow it by more than
    ///   ``maximumGrowth`` in all.
    public func redactedValue(_ value: Any) throws -> Any {
        var budget = Self.maximumGrowth
        return try redactValue(value, at: Date(), budget: &budget)
    }

    private func redactValue(_ value: Any, at date: Date, budget: inout Int) throws -> Any {
        switch value {
        case let text as String:
            return try redact(text, at: date, budget: &budget)
        case let list as [Any]:
            return try list.map { try redactValue($0, at: date, budget: &budget) }
        case let object as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in object { out[try redact(key, at: date, budget: &budget)] = try redactValue(item, at: date, budget: &budget) }
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
                let masked = try redact(form, at: date, budget: &budget)
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
