import Foundation

/// Where an appshot should be delivered.
enum AppshotRoute: Equatable {
    /// Append to (and stage into) an existing agent surface.
    case append(workspaceId: UUID, panelId: UUID)
    /// No recent appshot route or interacted-with agent qualifies within the
    /// recency window. This is a "no recent target" signal, not an instruction
    /// to open a new workspace: `AppshotController` still prefers the active
    /// agent (the front window's focused terminal) and only opens a fresh
    /// workspace when no terminal surface exists.
    case noRecentTarget
}
