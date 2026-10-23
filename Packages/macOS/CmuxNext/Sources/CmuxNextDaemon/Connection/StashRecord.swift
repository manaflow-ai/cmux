import Foundation

/// One stash (`stash-v1`, a native OneTab; `stash.list`): browser pages, and with
/// `stash-workspaces-v1` whole workspaces, closed into a named group, kept until restored or
/// deleted. Members are in restore order; `stash.restore` and `stash.delete` name them by their
/// stable `id`.
public struct StashRecord: Decodable, Sendable, Equatable {
    /// One stashed member: a page, or a whole workspace (`kind` `workspace`).
    public struct Page: Decodable, Sendable, Equatable {
        /// What a member is.
        public enum Kind: String, Decodable, Sendable {
            /// One browser page.
            case tab
            /// A whole workspace with every tab it had (terminals too).
            case workspace
        }

        /// One tab of a stashed workspace, for display.
        public struct WorkspaceTab: Decodable, Sendable, Equatable {
            /// The tab's kind (`terminal`, `browser`, ...).
            public var kind: String?
            public var title: String?
            /// Only for a web page, with secret-looking query keys stripped.
            public var url: String?
        }

        /// The member's stable id in its stash.
        public var id: String
        /// `tab` when the daemon names no kind (a `stash-v1` daemon lists only pages).
        public var kind: Kind
        /// The page, with secret-looking query keys stripped by the daemon; nil for a workspace.
        public var url: String?
        public var title: String?
        /// A workspace's name.
        public var name: String?
        /// Nil for the default browser profile.
        public var browserProfileID: String?
        /// The workspace it left; nil for an imported page or a whole workspace.
        public var workspaceID: ResourceID?
        /// A workspace's tab count (every screen).
        public var tabCount: Int?
        /// A workspace's first tabs, for display.
        public var tabs: [WorkspaceTab]

        enum CodingKeys: String, CodingKey {
            case id, kind, url, title, name, tabs
            case browserProfileID = "browser_profile_id"
            case workspaceID = "workspace_id"
            case tabCount = "tab_count"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .tab
            url = try c.decodeIfPresent(String.self, forKey: .url)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            browserProfileID = try c.decodeIfPresent(String.self, forKey: .browserProfileID)
            workspaceID = try c.decodeIfPresent(ResourceID.self, forKey: .workspaceID)
            tabCount = try c.decodeIfPresent(Int.self, forKey: .tabCount)
            tabs = try c.decodeIfPresent([WorkspaceTab].self, forKey: .tabs) ?? []
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
