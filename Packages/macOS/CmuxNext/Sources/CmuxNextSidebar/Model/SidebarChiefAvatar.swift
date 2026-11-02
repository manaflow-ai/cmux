public import Foundation

/// The operating Chief's existing profile face, never a harness icon or a guess from a row title.
public nonisolated enum SidebarChiefAvatar: Hashable, Sendable {
    case picture(URL)
    case text(String)
}
