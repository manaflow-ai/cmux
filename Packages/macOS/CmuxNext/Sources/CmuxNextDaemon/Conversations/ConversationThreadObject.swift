import Foundation

/// A thread root's object (`thread` on a root `Message`, conversation-thread-objects-v1): its title,
/// owner and resolution. Absent fields are unset; the whole object is absent when all are.
public struct ConversationThreadObject: Codable, Sendable, Hashable {
    public var title: String?
    /// The participant who owns the thread (a person or a Chief).
    public var owner: String?
    /// Set by `status: resolved`; the thread reads as resolved only while no live reply has a seq above `seq`.
    public var resolved: Resolution?

    public struct Resolution: Codable, Sendable, Hashable {
        public var by: String
        public var at: String
        public var seq: UInt64
    }

    public init(title: String? = nil, owner: String? = nil, resolved: Resolution? = nil) {
        self.title = title
        self.owner = owner
        self.resolved = resolved
    }
}

/// `conversation-link-resolve` (conversation-tree-v1): a permalink's conversation, message, the
/// message's top thread root and the path from that root down to it.
public struct ConversationLinkResolveRequest: DaemonRequest {
    public typealias Response = ConversationLinkTarget
    public static let commandName: DaemonCommandName = "conversation-link-resolve"
    public static let requiredCapability: String? = "conversation-tree-v1"
    public var url: String
    public init(url: String) { self.url = url }
}

public struct ConversationLinkTarget: Decodable, Sendable, Hashable {
    public var url: String
    public var message: ConversationMessage?
    public var threadRoot: String?
    public var path: [String]

    enum CodingKeys: String, CodingKey {
        case url, message, path
        case threadRoot = "thread_root"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        message = try c.decodeIfPresent(ConversationMessage.self, forKey: .message)
        threadRoot = try c.decodeIfPresent(String.self, forKey: .threadRoot)
        path = try c.decodeIfPresent([String].self, forKey: .path) ?? []
    }
}
