public import Foundation

/// One deduplicated problem: every occurrence with the same fingerprint, counted, with one sample.
public struct ErrorEntry: Sendable, Equatable, Codable {
    /// 16 hex digits of FNV-1a over the source, the message template and the top frame.
    public var fingerprint: String
    /// Where it happened (see ``ErrorEvent/source``).
    public var source: String
    /// The worst level seen for this fingerprint.
    public var level: ErrorLevel
    /// The message with numbers, ids, paths and quoted text replaced by placeholders.
    public var template: String
    /// The newest occurrence's message, redacted and bounded.
    public var sample: String
    /// The top frame, if the source gave one.
    public var topFrame: String?
    /// The newest occurrence's context, redacted and bounded.
    public var context: [String: String]
    /// Occurrences seen, including ones only counted during a storm.
    public var count: UInt64
    /// First occurrence, milliseconds since 1970.
    public var firstMs: Int64
    /// Newest occurrence, milliseconds since 1970.
    public var lastMs: Int64

    /// The first occurrence as a date.
    public var firstSeen: Date { Date(timeIntervalSince1970: Double(firstMs) / 1000) }
    /// The newest occurrence as a date.
    public var lastSeen: Date { Date(timeIntervalSince1970: Double(lastMs) / 1000) }

    enum CodingKeys: String, CodingKey {
        case fingerprint = "fp"
        case source, level, template, sample
        case topFrame = "frame"
        case context = "ctx"
        case count
        case firstMs = "first_ms"
        case lastMs = "last_ms"
    }

    /// Makes an entry (the journal makes them; tests and readers decode them).
    public init(fingerprint: String, source: String, level: ErrorLevel, template: String, sample: String,
                topFrame: String?, context: [String: String], count: UInt64, firstMs: Int64, lastMs: Int64) {
        self.fingerprint = fingerprint
        self.source = source
        self.level = level
        self.template = template
        self.sample = sample
        self.topFrame = topFrame
        self.context = context
        self.count = count
        self.firstMs = firstMs
        self.lastMs = lastMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        source = try c.decode(String.self, forKey: .source)
        level = try c.decode(ErrorLevel.self, forKey: .level)
        template = try c.decode(String.self, forKey: .template)
        sample = try c.decode(String.self, forKey: .sample)
        topFrame = try c.decodeIfPresent(String.self, forKey: .topFrame)
        context = try c.decodeIfPresent([String: String].self, forKey: .context) ?? [:]
        count = try c.decode(UInt64.self, forKey: .count)
        firstMs = try c.decode(Int64.self, forKey: .firstMs)
        lastMs = try c.decode(Int64.self, forKey: .lastMs)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(source, forKey: .source)
        try c.encode(level, forKey: .level)
        try c.encode(template, forKey: .template)
        try c.encode(sample, forKey: .sample)
        try c.encodeIfPresent(topFrame, forKey: .topFrame)
        if !context.isEmpty { try c.encode(context, forKey: .context) }
        try c.encode(count, forKey: .count)
        try c.encode(firstMs, forKey: .firstMs)
        try c.encode(lastMs, forKey: .lastMs)
    }
}
