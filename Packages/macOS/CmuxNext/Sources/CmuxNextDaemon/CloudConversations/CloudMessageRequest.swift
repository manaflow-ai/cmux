import Foundation

/// One message request: who invited the user into which conversation, and a preview. It names
/// no address and no account id; `conversation` is the only id.
public struct CloudMessageRequest: Decodable, Sendable, Hashable {
    public var conversation: String
    /// The inviter's display name.
    public var inviter: String
    public var isGroup: Bool
    /// A group's title, when it has one.
    public var title: String?
    /// The inviter's newest message (at most 140 characters), or "".
    public var preview: String
    public var createdAt: Date?
    public var expiresAt: Date?
    /// The inviter's verified email has the user's company domain (DESIGN 2.4).
    public var trusted: Bool

    enum CodingKeys: String, CodingKey {
        case conversation, inviter, kind, title, preview, trusted
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(String.self, forKey: .conversation)
        inviter = try c.decodeIfPresent(String.self, forKey: .inviter) ?? ""
        isGroup = try c.decodeIfPresent(String.self, forKey: .kind) == "group"
        title = try c.decodeIfPresent(String.self, forKey: .title).flatMap { $0.isEmpty ? nil : $0 }
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(Self.date)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt).flatMap(Self.date)
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
    }

    /// The Worker's ISO 8601 times, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
