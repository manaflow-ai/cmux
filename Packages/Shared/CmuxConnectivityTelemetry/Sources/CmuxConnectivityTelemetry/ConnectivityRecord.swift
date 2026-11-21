import Foundation

/// What is kept of one ``ConnectivityEvent`` for an audience: one line of the device's journal
/// and what the app's remote sinks send.
public struct ConnectivityRecord: Sendable, Equatable, Codable {
    public var date: Date
    public var audience: ConnectivityAudience
    public var area: ConnectivityEvent.Area
    public var name: String
    public var outcome: ConnectivityEvent.Outcome
    public var fields: [String: ConnectivityEvent.Value]
    /// The event's free text; always nil for ``ConnectivityAudience/everyone``.
    public var detail: String?
    /// One kept record stands for this many events of its key (1: every event is kept).
    public var sampleRate: Int
    /// Events of any key the hourly budget dropped since the last kept record.
    public var droppedBefore: Int

    enum CodingKeys: String, CodingKey {
        case date = "t"
        case audience = "tier"
        case area
        case name = "event"
        case outcome
        case fields
        case detail
        case sampleRate = "sample_rate"
        case droppedBefore = "dropped_before"
    }

    public init(date: Date, audience: ConnectivityAudience, area: ConnectivityEvent.Area, name: String,
                outcome: ConnectivityEvent.Outcome, fields: [String: ConnectivityEvent.Value], detail: String?,
                sampleRate: Int, droppedBefore: Int) {
        self.date = date
        self.audience = audience
        self.area = area
        self.name = name
        self.outcome = outcome
        self.fields = fields
        self.detail = detail
        self.sampleRate = sampleRate
        self.droppedBefore = droppedBefore
    }

    /// `area.name`.
    public var key: String { "\(area.rawValue).\(name)" }

    /// One line, newest fields sorted, for a journal or a log.
    public var summary: String {
        var parts = ["\(key) \(outcome.rawValue)"]
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .code(let text), .text(let text): parts.append("\(field)=\(text)")
            case .number(let number):
                parts.append(number.rounded() == number ? "\(field)=\(Int(number))" : "\(field)=\(number)")
            case .flag(let flag): parts.append("\(field)=\(flag)")
            }
        }
        if let detail, !detail.isEmpty { parts.append("detail=\(detail)") }
        if sampleRate > 1 { parts.append("sample=1/\(sampleRate)") }
        if droppedBefore > 0 { parts.append("dropped_before=\(droppedBefore)") }
        return parts.joined(separator: " ")
    }

    /// The record as one JSON line (no trailing newline).
    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(ConnectivityRecord.timestampStyle))
        }
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// UTC ISO 8601 with milliseconds (a value type: no formatter is made per record).
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
