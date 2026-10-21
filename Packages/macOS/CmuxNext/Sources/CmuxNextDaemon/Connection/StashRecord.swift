import Foundation

/// One stash (`stash-v1`, a native OneTab; `stash.list`): browser pages
/// closed into a named group, kept until restored or deleted. Members are in
/// restore order; `stash.restore` and `stash.delete` name them by their stable `id`.
public struct StashRecord: Decodable, Sendable, Equatable {
    /// One stashed page.
    public struct Page: Decodable, Sendable, Equatable {
        /// The member's stable id in its stash.
        public var id: String
        /// The page, with secret-looking query keys stripped by the daemon.
        public var url: String
        public var title: String?
        /// Nil for the default browser profile.
        public var browserProfileID: String?
        /// The workspace it left; nil for an imported page.
        public var workspaceID: ResourceID?

        enum CodingKeys: String, CodingKey {
            case id, url, title
            case browserProfileID = "browser_profile_id"
            case workspaceID = "workspace_id"
        }
    }

    /// The stash's state id.
    public var id: String
    /// The workspace the pages left, or the imported group's name.
    public var name: String?
    /// Unix milliseconds of the stash (an imported group's own time).
    public var createdAtMs: UInt64
    public var members: [Page]

    enum CodingKeys: String, CodingKey {
        case id, name, members
        case createdAtMs = "created_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // A `decimal`: an unsigned integer in a string.
        createdAtMs = UInt64(try c.decode(String.self, forKey: .createdAtMs)) ?? 0
        members = try c.decode([Page].self, forKey: .members)
    }
}
