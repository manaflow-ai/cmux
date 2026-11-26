import Foundation

/// Owner-assigned conversation id (`conv_…`). DM ids are deterministic on the
/// owner side (hash of the two sorted user ids), so a client never creates a
/// duplicate DM.
public struct ConversationID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Owner-assigned message id (`msg_…`).
public struct MessageID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A human (`user_…`) or an agent principal (`agent_…`), such as a Chief.
public struct ParticipantID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Client-chosen idempotency key. For `message.send` it is also the
/// message's `client_msg_id`, which is how the owner's echo settles the intent.
public struct IdempotencyKey: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Who of the Chief's team wrote a message whose `client_msg_id` this is:
    /// `voice:<name>:<rest>` (optchat-chief `voice.rs`), e.g. `desk` for the
    /// front desk. Nil for every other key.
    public var voice: String? {
        guard rawValue.hasPrefix("voice:") else { return nil }
        let rest = rawValue.dropFirst("voice:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon]
        let allowed = name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return !name.isEmpty && allowed ? String(name) : nil
    }

    /// A fresh random key (`cmk_` + 26 lowercase base32 characters).
    public static func make() -> IdempotencyKey {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    public static func make<G: RandomNumberGenerator>(using generator: inout G) -> IdempotencyKey {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var key = "cmk_"
        for _ in 0..<26 { key.append(alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))]) }
        return IdempotencyKey(key)
    }
}

/// Per-conversation sequence number: 1-based and dense, assigned by the owner.
public typealias Seq = UInt64

/// Per-owner revision: increases by exactly one per committed op, so a gap
/// tells a mirror to refetch.
public typealias Revision = UInt64
