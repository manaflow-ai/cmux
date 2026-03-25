import Foundation

/// A top-level sidebar entry is simply a workspace UUID.
/// Workspaces that have children render their own collapse chevron and
/// indented child list — no separate group container is needed.
typealias SidebarItem = UUID
