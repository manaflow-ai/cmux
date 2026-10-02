import Foundation

// The sidebar's section layout (plans/cmux-next/sidebar-sections.md 4):
// an ordered list of sections in three regions. The workspace store owns
// the document (`sidebar-layout-v1`); clients render it and send
// `SidebarLayoutOp`s. Field names match the wire (snake_case).

/// Where a section sits: sticky at the top, in the scrolling middle, or
/// sticky at the bottom.
public nonisolated enum SidebarRegion: String, Hashable, Sendable, Codable, CaseIterable {
    case top
    case middle
    case bottom
}

/// How a section's rows look: `builtIn` rows read as app chrome (Home);
/// `list` rows look like workspace rows.
public nonisolated enum SectionLook: String, Hashable, Sendable, Codable, CaseIterable {
    case builtIn = "built_in"
    case list

    /// An unknown look (from a newer app) reads as list (L5).
    public init(from decoder: any Decoder) throws {
        self = SectionLook(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .list
    }
}

/// What a section holds: its own items, or the workspace list (exactly
/// one section, invariant L1).
public nonisolated enum SectionContent: String, Hashable, Sendable, Codable {
    case items
    case workspaces
}
