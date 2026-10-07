import Foundation

/// A Live Activity's content state. The feed owner sends the same JSON in
/// `aps.content-state` (ActivityKit decodes it with default keys, so the
/// names and the plain `started` number are part of the wire contract).
public struct AgentActivityState: Codable, Hashable, Sendable {
    public var phase: AgentActivityPhase
    /// One line: the task, or in needs-input the request's title.
    public var title: String
    public var detail: String?
    /// Unix seconds when the agent started (the elapsed timer counts from it).
    public var started: Double
    /// The open request in needs-input; a tap opens it.
    public var item: String?

    public init(phase: AgentActivityPhase, title: String, detail: String? = nil, started: Date, item: String? = nil) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.started = started.timeIntervalSince1970
        self.item = item
    }

    public var startedAt: Date { Date(timeIntervalSince1970: started) }

    /// A new activity id in the owner's pattern (`act_` + 2-64 letters and digits).
    public static func makeID() -> String {
        "act_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Whether `id` matches the owner's activity id pattern.
    public static func isActivityID(_ id: String) -> Bool {
        guard id.hasPrefix("act_") else { return false }
        let rest = id.dropFirst(4)
        return (2...64).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
