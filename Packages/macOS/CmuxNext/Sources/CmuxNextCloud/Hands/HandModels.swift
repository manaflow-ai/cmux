public import Foundation

/// A hand's permission level (docs/chief-hands.md). The rules (which change is a raise) are
/// cmux-tui's `cmux_cloud_wire::hands`; the app only names a level.
public enum HandLevel: String, Sendable, CaseIterable, Codable {
    case full, auto, ask
    case readOnly = "read-only"
}

/// The profile a hand was paired with; an owner default level applies per profile.
public enum HandProfile: String, Sendable, CaseIterable, Codable {
    case sandbox, mac
}

/// One of the owner's hands, as the hands engine read it (`GET /v1/hands`).
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
}

/// A hand request that waits for the owner, as the hands engine reported it.
public struct HandApproval: Sendable, Equatable, Decodable {
    public var hand: String
    public var id: String
    /// What the hand asks to do, as one line.
    public var summary: String
    public var at: Date
    /// The banner id and the service's key: one per approval.
    public var key: String

    enum CodingKeys: String, CodingKey { case hand, id, summary, at, key }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (hand, id, summary, key) = try (c.decode(String.self, forKey: .hand), c.decode(String.self, forKey: .id),
                                        c.decode(String.self, forKey: .summary), c.decode(String.self, forKey: .key))
        at = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .at) / 1000)
    }
}

/// How a waiting approval ended (`hand-approval-settled.outcome`).
public enum HandApprovalOutcome: String, Sendable, Decodable {
    case allowed, denied, expired
}
