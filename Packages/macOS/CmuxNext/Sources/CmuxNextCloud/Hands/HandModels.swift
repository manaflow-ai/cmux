public import Foundation

/// A hand's permission level (docs/chief-hands.md, backend hand-levels.ts). The owner sets it; a
/// raise (to a looser level) needs the owner's presence proof, a lower needs none.
public enum HandLevel: String, Sendable, CaseIterable, Codable {
    case full, auto, ask
    case readOnly = "read-only"

    /// Stricter to looser, as the server ranks them.
    var rank: Int {
        switch self {
        case .readOnly: 0
        case .ask: 1
        case .auto: 2
        case .full: 3
        }
    }

    /// Whether `self` to `level` loosens the hand.
    public func isRaise(to level: HandLevel) -> Bool { level.rank > rank }
}

/// The profile a hand was paired with; an owner default level applies per profile.
public enum HandProfile: String, Sendable, CaseIterable, Codable {
    case sandbox, mac
}

/// One of the owner's hands (`GET /v1/hands`).
public struct HandSummary: Sendable, Equatable, Decodable {
    public var hand: String
    public var name: String
    public var profile: HandProfile?
    public var online: Bool
    public var level: HandLevel?
    public var pendingApprovals: Int?

    enum CodingKeys: String, CodingKey {
        case hand, name, profile, online, level
        case pendingApprovals = "pending_approvals"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hand = try c.decode(String.self, forKey: .hand)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)).flatMap(HandProfile.init(rawValue:))
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        level = (try? c.decodeIfPresent(String.self, forKey: .level)).flatMap(HandLevel.init(rawValue:))
        pendingApprovals = try? c.decodeIfPresent(Int.self, forKey: .pendingApprovals)
    }
}

/// A hand request that waits for the owner (`hand-approval-pending`, or the launch read
/// `GET /v1/hands/<hand>/approvals`).
public struct HandApproval: Sendable, Equatable {
    public var hand: String
    public var id: String
    /// What the hand asks to do, as one line (``HandApproval/describe(_:)``).
    public var summary: String
    public var at: Date

    /// The banner id and the service's key: one per approval.
    public var key: String { "hand-approval.\(hand).\(id)" }

    public init(hand: String, id: String, summary: String, at: Date) {
        (self.hand, self.id, self.summary, self.at) = (hand, id, summary, at)
    }

    /// Parses one approval object; `hand` is the list's hand for the launch read.
    init?(_ object: [String: Any], hand fallback: String? = nil) {
        guard let hand = object["hand"] as? String ?? fallback, HandIDs.isHand(hand),
              let id = object["id"] as? String, HandIDs.isApproval(id) else { return nil }
        let at = (object["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        self.init(hand: hand, id: id, summary: Self.describe(object["summary"]), at: at)
    }

    /// One line from the hand's summary object (`action` and its argv, paths, title or prompt).
    static func describe(_ summary: Any?) -> String {
        guard let object = summary as? [String: Any] else { return (summary as? String).map { String($0.prefix(300)) } ?? "" }
        let action = object["action"] as? String ?? ""
        let detail: String? = (object["argv"] as? [Any]).map { $0.map { "\($0)" }.joined(separator: " ") }
            ?? (object["title"] as? String)
            ?? (object["paths"] as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") }
            ?? (object["prompt"] as? String)
        let line = [action, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
        return String(line.prefix(300))
    }
}

/// How a waiting approval ended (`hand-approval-settled.outcome`).
public enum HandApprovalOutcome: String, Sendable {
    case allowed, denied, expired
}

/// The ids the client accepts in a path or a signed text (backend hand-routes.ts).
enum HandIDs {
    static func isHand(_ id: String) -> Bool { id.range(of: #"^hand_[a-z2-7]{20}$"#, options: .regularExpression) != nil }
    static func isApproval(_ id: String) -> Bool { id.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil }
}

/// The texts a person's app signs (backend hand-levels.ts). The app builds each one itself from
/// ids it checked; it never signs a text that the server or the wire sent.
enum HandProofText {
    /// The install key signs this to register the presence key of `install`.
    static func presenceRegistration(environment: String, install: String, x: String, y: String) -> String {
        "cmux-hand-presence-key:\(environment):\(install):\(x):\(y)"
    }

    /// The presence key signs this to raise `target` (a hand id, or `default:<profile>`) to `level`.
    static func level(environment: String, target: String, level: HandLevel, nonce: String) -> String {
        "cmux-hand-level:\(environment):\(target):\(level.rawValue):\(nonce)"
    }

    /// The install key signs this to allow one waiting request.
    static func approval(environment: String, hand: String, id: String) -> String {
        "cmux-hand-approval:\(environment):\(hand):\(id):allow"
    }
}
