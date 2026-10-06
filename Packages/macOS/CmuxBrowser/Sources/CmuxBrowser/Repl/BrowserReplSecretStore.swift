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
/// JSON- and JavaScript-escaped, HTML-escaped (numeric references and
/// the legacy named ones, with or without the semicolon), character by character in any mix, and Base64-wrapped
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
/// while a server can still accept them (the current 30-second window and
/// the windows on each side, the clock skew RFC 6238 servers allow): they
/// are capture masks for the secret's domains, and in text every whole
/// six-digit number is masked as `<secret:name>` while the session holds a
/// TOTP secret, whatever its digits.
///
/// Masking by value runs over data the agent chooses (what it prints,
/// writes, or has a page echo), so a mask that appears only where the data
/// equals a held value answers the agent's guess. A value from a set the
/// agent can list whole in one call, a TOTP code or a digit-only value of
/// at most ``maximumDigitsMaskedByShape`` digits (a PIN), is therefore
/// masked by its shape (``masksByShape(_:)``): every whole number of its
/// length, as text or a JSON number, gets its mask, and its encoded forms
/// are not looked for. Any other value is masked by value, so a value an
/// agent can guess (a short or dictionary password) can still be confirmed
/// by printing guesses: value masking keeps a value out of what pages and
/// files hand back, not away from an agent that guesses it.
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
    /// The masks of the values masked by their shape (``masksByShape(_:)``),
    /// by their number of digits (index), in the order they were held.
    private var digitRunMasks: [[String]] = []
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
    /// The longest digit-only value masked by its shape: a whole number of
    /// up to 8 digits has at most 10^8 forms, which one call lists whole
    /// (a 900 MB file, under a session's 2 GiB of writes).
    public static let maximumDigitsMaskedByShape = 8
    /// The digits of a TOTP code.
    static let totpDigits = 6

    /// Whether `value` is masked by its shape instead of by comparison:
    /// it is digits only, at most ``maximumDigitsMaskedByShape`` of them.
    static func masksByShape(_ value: String) -> Bool {
        let utf8 = value.utf8
        return !utf8.isEmpty && utf8.count <= maximumDigitsMaskedByShape
            && utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

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
        try register(name: name, value: value, domains: rawDomains, totp: totp, title: title, rebuild: true)
    }

    /// ``set(name:value:domains:totp:title:)``; with `rebuild` false the
    /// caller rebuilds the masks once after a batch (``load(_:isCancelled:)``)
    /// instead of after every value. A value's earlier masks stay until then.
    private func register(name: String, value: String, domains rawDomains: [String], totp: Bool, title: String, rebuild: Bool) throws {
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
            if rebuild { rebuildLocked() }
        }
    }

    /// Registers `value` as a literal under the internal `key`, masked as
    /// `<secret:maskName>`. For values another session typed
    /// (``BrowserReplTypedSecrets``): the value is the text the field holds
    /// (a TOTP secret's code, not its seed), so no TOTP rule applies, and
    /// `key` keeps values that share a name apart.
    ///
    /// Bounded like ``set(name:value:domains:totp:title:)``: a value past
    /// ``maximumValueBytes``, more than ``maximumDomainsPerValue`` domains,
    /// or a new key past ``maximumTypedValues`` is refused (`invalid`), so a
    /// reader's store cannot grow without bound. The registry refuses to
    /// type such a value first (``BrowserReplTypedSecrets/record(tab:name:value:domains:typist:)``).
    func setLiteral(key: String, maskName: String, value: String, domains: [BrowserReplDomainPattern]) throws {
        guard !value.isEmpty else { return }
        try Self.checkTypedValue(value, domains: domains)
        try lock.withLock {
            let entry = Entry(name: key, value: value, domains: domains, totp: false, maskName: maskName)
            guard entries[key] == nil else {
                entries[key] = entry
                rebuildLocked()
                return
            }
            guard entries.count - registered.count < Self.maximumTypedValues else {
                throw Self.tooManyTypedValues
            }
            order.append(key)
            entries[key] = entry
            // A new literal only adds a value: insert it where the longest-
            // first order puts it instead of rebuilding, so filling a store
            // is not quadratic.
            codeCache = nil
            if Self.masksByShape(value) {
                addDigitRunMaskLocked(length: value.utf8.count, mask: "<secret:\(maskName)>")
                return
            }
            let length = entry.compiled.utf8.count
            let index = values.firstIndex { $0.utf8.count < length } ?? values.endIndex
            values.insert(entry.compiled, at: index)
            if let number = Self.numericValue(value), numericMasks[Self.numericKey(number)] == nil {
                numericMasks[Self.numericKey(number)] = "<secret:\(maskName)>"
            }
        }
    }

    /// The most values other sessions typed that a reader masks at once
    /// (``setLiteral(key:maskName:value:domains:)``,
    /// ``BrowserReplTypedSecrets``).
    public static let maximumTypedValues = 4096

    static let tooManyTypedValues = BrowserReplDriverError(
        code: "invalid",
        message: "the open tabs hold \(maximumTypedValues) values typed from secrets, the most cmux keeps masked; close tabs that sessions typed secrets into, then type it again"
    )

    /// Refuses a typed value past the bounds a registered one has.
    static func checkTypedValue(_ value: String, domains: [BrowserReplDomainPattern]) throws {
        guard value.utf8.count <= maximumValueBytes else {
            throw BrowserReplDriverError(code: "invalid", message: "a typed secret value is at most \(maximumValueBytes) bytes (UTF-8), got \(value.utf8.count)")
        }
        guard domains.count <= maximumDomainsPerValue else {
            throw BrowserReplDriverError(code: "invalid", message: "a typed secret value has at most \(maximumDomainsPerValue) domains, got \(domains.count)")
        }
    }

    /// Loads reference C's `sensitive_data` shape:
    /// `{ "<domain pattern>": { name: value | { value, totp } } }`.
    /// A name repeated with the same value under several patterns gets every pattern.
    /// - Returns: The names loaded, in order.
    /// - Throws: `CancellationError` when `isCancelled` says so between
    ///   entries (it runs on the session's JavaScript thread, inside a
    ///   synchronous host call). The masks are rebuilt once when it returns
    ///   or throws, so what it loaded is masked either way.
    public func load(_ object: Any, isCancelled: () -> Bool = { false }) throws -> [String] {
        if isCancelled() { throw CancellationError() }
        guard let groups = object as? [String: Any] else {
            throw invalid("secrets.load: expected { \"<domain pattern>\": { name: value } }")
        }
        // Each pattern adds a domain to a secret, so more patterns than the
        // store can hold domains is refused before they are sorted.
        let maximumPatterns = Self.maximumSecrets * Self.maximumDomains
        guard groups.count <= maximumPatterns else {
            throw invalid("secrets.load: \(groups.count) domain patterns, past the \(maximumPatterns) the store can hold")
        }
        var names: [String] = []
        var changed = false
        defer { if changed { lock.withLock { rebuildLocked() } } }
        for (pattern, rawEntries) in groups.sorted(by: { $0.key < $1.key }) {
            if isCancelled() { throw CancellationError() }
            guard let group = rawEntries as? [String: Any] else {
                throw invalid("secrets.load: \(Self.quote(pattern)): a secret needs domains; expected { \"<domain pattern>\": { name: value } }")
            }
            for (name, raw) in group.sorted(by: { $0.key < $1.key }) {
                if isCancelled() { throw CancellationError() }
                let object = raw as? [String: Any]
                guard let value = (object?["value"] ?? raw) as? String else {
                    throw invalid("secrets.load: \(name): value: expected a non-empty string")
                }
                let prior = lock.withLock { entries[name] }
                let domains = prior.map { $0.value == value ? $0.domains.map(\.raw) + [pattern] : [pattern] } ?? [pattern]
                let totp = (object?["totp"] as? Bool ?? false) || (prior?.totp ?? false)
                try register(name: name, value: value, domains: domains, totp: totp, title: "secrets.load", rebuild: false)
                changed = true
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

    /// The largest file `secrets.load(path)` reads: far more than a full
    /// store's values and patterns, and small enough that parsing it,
    /// which nothing can stop midway on the session's JavaScript thread,
    /// stays short.
    public static let maximumLoadFileBytes = 8 << 20

    /// Why `secrets.load` refuses a file's bytes, or nil. File reads mask a
    /// loaded value by its UTF-8 bytes and their escaped forms, except a
    /// short digit value's, which is masked by its shape alone; a source
    /// that holds a value some other way would read back unmasked through
    /// `fs`. So a source must be UTF-8 (JSON's parser also reads UTF-16
    /// and UTF-32: a byte order mark or a NUL byte, which UTF-8 JSON never
    /// holds, says it is one of them) and may not spell a digit with a JSON
    /// escape (`\u0030` to `\u0039`), the only other way JSON writes one.
    static func loadSourceRefusal(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let utf8Message = "is not UTF-8; save it as UTF-8, so files read back can mask its values"
        if bytes.starts(with: [0xfe, 0xff]) || bytes.starts(with: [0xff, 0xfe]) || bytes.contains(0) { return utf8Message }
        guard String(data: data, encoding: .utf8) != nil else { return utf8Message }
        let escape = Array(#"\u003"#.utf8)
        var index = 0
        while index + escape.count < bytes.count {
            if bytes[index] == escape[0], Array(bytes[index..<(index + escape.count)]) == escape,
               (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index + escape.count]) {
                return "spells a digit with a JSON escape (\\u0030 to \\u0039); write digits as they are, so files read back can mask its values"
            }
            index += 1
        }
        return nil
    }

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
        let byShape = { (entry: Entry) in !entry.totp && Self.masksByShape(entry.value) }
        values = masked.filter { !byShape($0) }.map(\.compiled)
            .sorted { $0.utf8.count > $1.utf8.count }
        digitRunMasks = []
        for entry in masked {
            if entry.totp {
                addDigitRunMaskLocked(length: Self.totpDigits, mask: "<secret:\(entry.maskName)>")
            } else if byShape(entry) {
                addDigitRunMaskLocked(length: entry.value.utf8.count, mask: "<secret:\(entry.maskName)>")
            }
        }
        numericMasks = [:]
        for entry in masked where !entry.totp && !byShape(entry) {
            guard let number = Self.numericValue(entry.value) else { continue }
            numericMasks[Self.numericKey(number)] = numericMasks[Self.numericKey(number)] ?? "<secret:\(entry.maskName)>"
        }
    }

    /// Masks every whole number of `length` digits with `mask` too. Call
    /// with `lock` held.
    private func addDigitRunMaskLocked(length: Int, mask: String) {
        if digitRunMasks.count <= length {
            digitRunMasks += Array(repeating: [], count: length + 1 - digitRunMasks.count)
        }
        if !digitRunMasks[length].contains(mask) { digitRunMasks[length].append(mask) }
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
    fileprivate static func numericKey(_ number: Double) -> UInt64 {
        (number == 0 ? 0 : number).bitPattern
    }

    /// What this store masks now: values by comparison, whole numbers by
    /// their number of digits, and JSON numbers.
    fileprivate func snapshot() -> (values: [BrowserReplSecretScanner.Value], digitRunMasks: [[String]], numericMasks: [UInt64: String]) {
        lock.withLock { (values, digitRunMasks, numericMasks) }
    }

    /// Why masking withheld `count` bytes.
    static func limitMessage(_ count: Int) -> String {
        "masking secrets in these \(count) bytes would pass the redaction limit (growing them by more than \(maximumGrowth >> 20) MiB, or more matching work than the session's secrets allow for their length), so they are withheld"
    }

    /// The error masking `count` bytes past the limit throws.
    static func limitError(_ count: Int) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "invalid", message: limitMessage(count))
    }

    /// `text` with every registered value and its encodings masked, and the
    /// TOTP codes valid now. Text that masking would grow by more than
    /// ``maximumGrowth`` is replaced by a note saying it was withheld.
    public func redact(_ text: String) -> String {
        Redaction(stores: [self])?.redact(text) ?? text
    }

    /// `data` with every registered value and its encodings masked, text or
    /// binary alike: the value's UTF-8 bytes and their encoded forms are
    /// matched byte by byte. A value the bytes hold only compressed or in
    /// another encoding is not found.
    /// - Throws: `invalid` when masking would grow the bytes by more than
    ///   ``maximumGrowth``.
    public func redact(_ data: Data) throws -> Data {
        try Redaction(stores: [self])?.redact(data) ?? data
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
        try Redaction(stores: [self])?.redactedValue(value) ?? value
    }

    /// One masking of the values of one or more stores, taken at once:
    /// every value and TOTP code they hold is matched in a single pass over
    /// the original input (``BrowserReplSecretScanner``), so one store's
    /// mask never replaces part of another store's value before that value
    /// is looked for (a session registering a prefix of a value another
    /// session typed). A value several stores hold keeps the first store's
    /// mask.
    struct Redaction {
        private let scanner: BrowserReplSecretScanner
        private let numericMasks: [UInt64: String]

        /// `nil` when the stores mask nothing.
        init?(stores: [BrowserReplSecretStore]) {
            let snapshots = stores.map { $0.snapshot() }.filter { !$0.values.isEmpty || !$0.digitRunMasks.isEmpty }
            guard !snapshots.isEmpty else { return nil }
            // Every store's mask for a length, each once, in store order: one
            // mask for every whole number of that length.
            var runMasks: [[String]] = []
            for snapshot in snapshots {
                for (length, masks) in snapshot.digitRunMasks.enumerated() {
                    if runMasks.count <= length { runMasks += Array(repeating: [], count: length + 1 - runMasks.count) }
                    for mask in masks where !runMasks[length].contains(mask) { runMasks[length].append(mask) }
                }
            }
            // Each store's values are longest first; merge them keeping that
            // order, and the first store's value first among equal lengths.
            var values = snapshots[0].values
            var numericMasks = snapshots[0].numericMasks
            for snapshot in snapshots.dropFirst() {
                var merged: [BrowserReplSecretScanner.Value] = []
                merged.reserveCapacity(values.count + snapshot.values.count)
                var left = 0
                var right = 0
                while left < values.count || right < snapshot.values.count {
                    if right == snapshot.values.count
                        || (left < values.count && values[left].utf8.count >= snapshot.values[right].utf8.count) {
                        merged.append(values[left])
                        left += 1
                    } else {
                        merged.append(snapshot.values[right])
                        right += 1
                    }
                }
                values = merged
                numericMasks.merge(snapshot.numericMasks) { first, _ in first }
            }
            scanner = BrowserReplSecretScanner(
                values: values,
                digitRunMasks: runMasks.map { $0.isEmpty ? nil : Array($0.joined().utf8) }
            )
            self.numericMasks = numericMasks
        }

        /// `text` masked; text that masking would grow by more than
        /// ``BrowserReplSecretStore/maximumGrowth`` is replaced by a note
        /// saying it was withheld.
        func redact(_ text: String) -> String {
            redact(text, isCancelled: { false }) ?? text
        }

        /// `text` masked as ``redact(_:)`` does, or `nil` when `isCancelled`
        /// said so before the pass finished (the session's timeout cannot
        /// stop native work on its JavaScript thread any other way).
        func redact(_ text: String, isCancelled: () -> Bool) -> String? {
            var budget = BrowserReplSecretStore.maximumGrowth
            do {
                return try redact(text, budget: &budget, isCancelled: isCancelled)
            } catch is CancellationError {
                return nil
            } catch {
                return "<\(BrowserReplSecretStore.limitMessage(text.utf8.count))>"
            }
        }

        private func redact(_ text: String, budget: inout Int, isCancelled: () -> Bool) throws -> String {
            guard !text.isEmpty else { return text }
            var text = text
            let outcome = text.withUTF8 { scanner.redact($0, budget: &budget, isCancelled: isCancelled) }
            switch outcome {
            case .unchanged: return text
            case .redacted(let bytes): return String(decoding: bytes, as: UTF8.self)
            case .overLimit: throw BrowserReplSecretStore.limitError(text.utf8.count)
            case .cancelled: throw CancellationError()
            }
        }

        /// `data` masked, text or binary alike. `isCancelled` stops a long
        /// pass: the session's timeout cannot stop native work on its
        /// JavaScript thread any other way.
        /// - Throws: `invalid` when masking would grow it by more than
        ///   ``BrowserReplSecretStore/maximumGrowth``; `CancellationError`
        ///   when `isCancelled` said so first.
        func redact(_ data: Data, isCancelled: () -> Bool = { false }) throws -> Data {
            guard !data.isEmpty else { return data }
            var budget = BrowserReplSecretStore.maximumGrowth
            let outcome = data.withUnsafeBytes { scanner.redact($0.bindMemory(to: UInt8.self), budget: &budget, isCancelled: isCancelled) }
            switch outcome {
            case .unchanged: return data
            case .redacted(let bytes): return Data(bytes)
            case .overLimit: throw BrowserReplSecretStore.limitError(data.count)
            case .cancelled: throw CancellationError()
            }
        }

        /// A JSON document with every string (keys too) masked; text that
        /// is not JSON is masked as text. Parsing cannot stop midway, so
        /// `isCancelled` is asked before and after it, and between strings
        /// and chunks of a long string while masking.
        /// - Throws: `invalid` when masking would grow it by more than
        ///   ``BrowserReplSecretStore/maximumGrowth`` in all;
        ///   `CancellationError` when `isCancelled` said so first.
        func redactJSON(_ json: String, isCancelled: () -> Bool = { false }) throws -> String {
            if isCancelled() { throw CancellationError() }
            guard let value = JSONSerialization.browserReplValue(json) else { return try redactText(json, isCancelled: isCancelled) }
            if isCancelled() { throw CancellationError() }
            let masked = try redactedValue(value, isCancelled: isCancelled)
            if isCancelled() { throw CancellationError() }
            return try JSONSerialization.browserReplString(masked) ?? redactText(json, isCancelled: isCancelled)
        }

        private func redactText(_ text: String, isCancelled: () -> Bool) throws -> String {
            guard let masked = redact(text, isCancelled: isCancelled) else { throw CancellationError() }
            return masked
        }

        /// `value` (decoded JSON) with every string masked.
        /// - Throws: `invalid` when masking would grow it by more than
        ///   ``BrowserReplSecretStore/maximumGrowth`` in all;
        ///   `CancellationError` when `isCancelled` said so first (asked
        ///   once per ``BrowserReplSecretScanner/cancellationStride`` bytes
        ///   of strings and values, however short each string is).
        func redactedValue(_ value: Any, isCancelled: () -> Bool = { false }) throws -> Any {
            try withoutActuallyEscaping(isCancelled) { isCancelled in
                var walk = Walk(budget: BrowserReplSecretStore.maximumGrowth, isCancelled: isCancelled)
                return try redactValue(value, walk: &walk)
            }
        }

        /// A walk over decoded JSON: the growth it may still add, and the
        /// bytes handled since `isCancelled` was last asked.
        private struct Walk {
            var budget: Int
            var sinceCheck = 0
            let isCancelled: () -> Bool

            /// Counts `bytes` handled (and one for the node), asking
            /// `isCancelled` once a stride's worth has passed.
            mutating func advance(_ bytes: Int) throws {
                sinceCheck += bytes + 1
                guard sinceCheck >= BrowserReplSecretScanner.cancellationStride else { return }
                sinceCheck = 0
                if isCancelled() { throw CancellationError() }
            }
        }

        private func redact(_ text: String, walk: inout Walk) throws -> String {
            try walk.advance(text.utf8.count)
            return try redact(text, budget: &walk.budget, isCancelled: walk.isCancelled)
        }

        private func redactValue(_ value: Any, walk: inout Walk) throws -> Any {
            switch value {
            case let text as String:
                return try redact(text, walk: &walk)
            case let list as [Any]:
                try walk.advance(0)
                return try list.map { try redactValue($0, walk: &walk) }
            case let object as [String: Any]:
                try walk.advance(0)
                var out: [String: Any] = [:]
                for (key, item) in object { out[try redact(key, walk: &walk)] = try redactValue(item, walk: &walk) }
                return out
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                // A page can read a value as a number (`Number(field.value)`),
                // which drops leading zeros: a held value that is this number
                // is masked whatever its length.
                let double = number.doubleValue
                if double.isFinite, let mask = numericMasks[BrowserReplSecretStore.numericKey(double)] {
                    try walk.advance(0)
                    walk.budget -= max(0, mask.utf8.count - number.stringValue.utf8.count)
                    guard walk.budget >= 0 else { throw BrowserReplSecretStore.limitError(number.stringValue.utf8.count) }
                    return mask
                }
                // As text: a whole number of a length masked by its shape
                // (a TOTP code, a PIN) is masked whatever its digits.
                let form = number.stringValue
                let masked = try redact(form, walk: &walk)
                return masked != form ? masked : value
            default:
                try walk.advance(0)
                return value
            }
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

    static func totp(key: Data, time: TimeInterval, digits: Int = totpDigits, period: Double = totpPeriod) -> String {
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
