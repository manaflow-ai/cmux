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
/// and work are bounded: text that masking would grow by more than
/// ``maximumGrowth``, or that would take more matching work than its length
/// allows, is withheld, and bytes are refused. A session holds at most
/// ``maximumSecrets`` secrets of at most ``maximumValueBytes`` bytes with at
/// most ``maximumDomains`` domains each, and each value is compiled for
/// matching once, when it is registered.
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
        /// The value compiled for matching, once, when it is registered.
        let compiled: BrowserReplSecretScanner.Value

        init(name: String, value: String, domains: [BrowserReplDomainPattern], totp: Bool, maskName: String) {
            self.name = name
            self.value = value
            self.domains = domains
            self.totp = totp
            self.maskName = maskName
            compiled = BrowserReplSecretScanner.Value(value: value, mask: "<secret:\(maskName)>")
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// Values the session held under a name that was deleted, cleared or
    /// given another value, oldest first. They are no longer typed or
    /// listed, but stay masked for the session's life: the agent never saw
    /// them, and wherever they came from (a secrets file) still holds them.
    private var retired: [Entry] = []
    /// Every value the session held, its current and retired ones.
    private var heldValues: Set<String> = []
    private var values: [BrowserReplSecretScanner.Value] = []
    /// The mask of each held value that reads as a number (`0042`,
    /// `0012345678`, `3.140`), by the number's bits: a page that converts
    /// the value with `Number()` returns it as a JSON number.
    private var numericMasks: [UInt64: String] = [:]
    private var totpKeys: [(name: String, key: Data, domains: [BrowserReplDomainPattern])] = []
    private var codeCache: (window: Int64, codes: [ValidCodes])?

    private let publicSuffixes: BrowserReplPublicSuffixList

    /// - Parameter publicSuffixes: The list that refuses a secret's
    ///   wildcard domain over a public suffix (`*.com`).
    public init(publicSuffixes: BrowserReplPublicSuffixList = .system) {
        self.publicSuffixes = publicSuffixes
    }

    /// Whether the store masks nothing: it holds no value, current or retired.
    public var isEmpty: Bool { lock.withLock { entries.isEmpty && retired.isEmpty } }

    /// The most secrets a session registers (``set(name:value:domains:totp:title:)``).
    /// Every redaction matches every value, so the store a script fills
    /// stays bounded.
    public static let maximumSecrets = 256
    /// The longest value, in UTF-8 bytes.
    public static let maximumValueBytes = 4096
    /// The most domains one secret names.
    public static let maximumDomains = 64
    /// The most distinct values a session holds over its life, current and
    /// retired (deleted, cleared or replaced ones stay masked), so the
    /// values every redaction matches stay bounded.
    public static let maximumValuesPerSession = 1024
    /// The most distinct domains one value is registered for over a
    /// session's life, under all its names, current and retired: a retired
    /// value stays a capture mask on every one of them.
    public static let maximumDomainsPerValue = 1024

    /// Secrets registered through `set`, not values other sessions typed.
    private var registered: Set<String> = []
    /// Each registered secret's revision: a number no earlier `set` of any
    /// name had, so a value handed out for typing can be told apart from
    /// a later one under the same name (``isCurrent(_:revision:)``).
    private var revisions: [String: Int] = [:]
    private var lastRevision = 0

    /// Registers `name`. A secret needs at least one domain; a TOTP secret
    /// must be base32. Past ``maximumSecrets`` secrets, a value past
    /// ``maximumValueBytes`` or more than ``maximumDomains`` domains is refused.
    public func set(name: String, value: String, domains rawDomains: [String], totp: Bool, title: String) throws {
        guard name.range(of: "^[\\w.-]{1,64}$", options: .regularExpression) != nil else {
            throw invalid("\(title): name: expected letters, digits, _, . or - (at most 64), got \(Self.quote(name))")
        }
        guard !value.isEmpty else { throw invalid("\(title): \(name): value: expected a non-empty string") }
        guard value.utf8.count <= Self.maximumValueBytes else {
            throw invalid("\(title): \(name): value: at most \(Self.maximumValueBytes) bytes (UTF-8), got \(value.utf8.count)")
        }
        guard !rawDomains.isEmpty else {
            throw invalid("\(title): \(name): domains: expected the domains it may be typed into, such as [\"example.com\"]; a secret without domains is not accepted")
        }
        guard rawDomains.count <= Self.maximumDomains else {
            throw invalid("\(title): \(name): domains: at most \(Self.maximumDomains), got \(rawDomains.count)")
        }
        let domains = try rawDomains.map { try BrowserReplDomainPattern.parse($0, title: title, publicSuffixes: publicSuffixes) }
        let isTOTP = totp || name.hasSuffix("bu_2fa_code")
        if isTOTP, Self.base32Decode(value) == nil { throw invalid("secrets: a TOTP secret must be base32") }
        try lock.withLock {
            if !registered.contains(name), registered.count >= Self.maximumSecrets {
                throw invalid("\(title): \(name): a session holds at most \(Self.maximumSecrets) secrets; delete one (secrets.delete) first")
            }
            if !heldValues.contains(value), heldValues.count >= Self.maximumValuesPerSession {
                throw invalid("\(title): \(name): a session holds at most \(Self.maximumValuesPerSession) secret values over its life (deleted and replaced ones stay masked); reset the session (cmux browser repl reset NAME) for new ones")
            }
            var valueDomains = Set(domains.map(\.raw))
            for entry in order.compactMap({ entries[$0] }) + retired where entry.value == value {
                valueDomains.formUnion(entry.domains.map(\.raw))
            }
            if valueDomains.count > Self.maximumDomainsPerValue {
                throw invalid("\(title): \(name): a value is registered for at most \(Self.maximumDomainsPerValue) domains over the session's life (deleted and replaced registrations stay masked); reset the session (cmux browser repl reset NAME) for others")
            }
            registered.insert(name)
            heldValues.insert(value)
            if let previous = entries[name] {
                retireLocked(previous)
            } else {
                order.append(name)
            }
            entries[name] = Entry(name: name, value: value, domains: domains, totp: isTOTP, maskName: name)
            lastRevision += 1
            revisions[name] = lastRevision
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
            guard let removed = entries.removeValue(forKey: name) else { return false }
            retireLocked(removed)
            registered.remove(name)
            revisions.removeValue(forKey: name)
            order.removeAll { $0 == name }
            rebuildLocked()
            return true
        }
    }

    public func clear() {
        lock.withLock {
            for name in order { if let entry = entries[name] { retireLocked(entry) } }
            entries.removeAll()
            order.removeAll()
            registered.removeAll()
            revisions.removeAll()
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
        typing(name, at: date).map { ($0.text, $0.domains) }
    }

    /// ``valueToType(_:at:)`` with the secret's revision, read together.
    func typing(_ name: String, at date: Date = Date()) -> (text: String, domains: [BrowserReplDomainPattern], revision: Int)? {
        guard let (entry, revision) = lock.withLock({ entries[name].map { ($0, revisions[name] ?? 0) } }) else { return nil }
        if entry.totp {
            guard let key = Self.base32Decode(entry.value) else { return nil }
            return (Self.totp(key: key, time: date.timeIntervalSince1970), entry.domains, revision)
        }
        return (entry.value, entry.domains, revision)
    }

    /// Whether `name` still holds the secret of `revision` (from
    /// ``typing(_:at:)``): not deleted, cleared or set again since.
    public func isCurrent(_ name: String, revision: Int) -> Bool {
        lock.withLock { revisions[name] == revision }
    }

    /// Plain values, and the TOTP codes that are valid now, with their
    /// domains, for masking captures.
    public var captureMasks: [(value: String, domains: [BrowserReplDomainPattern])] {
        captureMasks(at: Date())
    }

    /// The values the session could type between `start` and `end`: every
    /// plain value it holds (current and retired), and each TOTP secret's
    /// codes of the windows from `start`'s to `end`'s (at most a day's).
    func typeableValues(from start: Date, to end: Date) -> [(value: String, domains: [BrowserReplDomainPattern])] {
        let (plain, keys) = lock.withLock {
            ((order.compactMap { entries[$0] } + retired).filter { !$0.totp }.map { ($0.value, $0.domains) }, totpKeys)
        }
        guard !keys.isEmpty else { return plain }
        let first = Int64(floor(start.timeIntervalSince1970 / Self.totpPeriod))
        let last = max(first, Int64(floor(end.timeIntervalSince1970 / Self.totpPeriod)))
        let windows = first...min(last, first + Int64(86_400 / Self.totpPeriod))
        return plain + keys.flatMap { entry in
            windows.map { (Self.totp(key: entry.key, time: Double($0) * Self.totpPeriod), entry.domains) }
        }
    }

    func captureMasks(at date: Date) -> [(value: String, domains: [BrowserReplDomainPattern])] {
        let plain = lock.withLock { (order.compactMap { entries[$0] } + retired).filter { !$0.totp }.map { ($0.value, $0.domains) } }
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

    /// Keeps `entry`'s value masked after its name lets go of it, on its
    /// domains and on those of every earlier retirement of the same value
    /// (one entry per value holds their union). Call with `lock` held.
    private func retireLocked(_ entry: Entry) {
        guard let index = retired.firstIndex(where: { $0.value == entry.value && $0.totp == entry.totp }) else {
            retired.append(entry)
            return
        }
        let kept = retired[index]
        let added = entry.domains.filter { domain in !kept.domains.contains { $0.raw == domain.raw } }
        guard !added.isEmpty else { return }
        retired[index] = Entry(name: kept.name, value: kept.value, domains: kept.domains + added, totp: kept.totp, maskName: kept.maskName)
    }

    private func rebuildLocked() {
        codeCache = nil
        let masked = order.compactMap { entries[$0] } + retired
        totpKeys = masked.filter(\.totp).compactMap { entry in
            Self.base32Decode(entry.value).map { (entry.maskName, $0, entry.domains) }
        }
        // Each value was compiled when it was registered; a change only reorders.
        values = masked.map(\.compiled)
            .sorted { $0.utf8.count > $1.utf8.count }
        numericMasks = [:]
        for entry in masked where !entry.totp {
            guard let number = Self.numericValue(entry.value) else { continue }
            numericMasks[Self.numericKey(number)] = numericMasks[Self.numericKey(number)] ?? "<secret:\(entry.maskName)>"
        }
    }

    /// The number JavaScript's `Number()` gives a value that is a decimal
    /// literal (digits with an optional sign, point and exponent, spaces
    /// around it), or `nil` for any other value.
    static func numericValue(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Double(trimmed), number.isFinite else { return nil }
        return number
    }

    /// `number`'s key in ``numericMasks``; `-0` is `0`.
    private static func numericKey(_ number: Double) -> UInt64 {
        (number == 0 ? 0 : number).bitPattern
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
        "masking secrets in these \(count) bytes would pass the redaction limit (growing them by more than \(maximumGrowth >> 20) MiB, or more matching work than the session's secrets allow for their length), so they are withheld"
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
            // A page can read a value as a number (`Number(field.value)`),
            // which drops leading zeros: a held value that is this number
            // is masked whatever its length.
            let double = number.doubleValue
            if double.isFinite, let mask = lock.withLock({ numericMasks[Self.numericKey(double)] }) {
                budget -= max(0, mask.utf8.count - number.stringValue.utf8.count)
                guard budget >= 0 else { throw invalid(Self.limitMessage(number.stringValue.utf8.count)) }
                return mask
            }
            // A TOTP code it reads that way drops a leading zero too.
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
