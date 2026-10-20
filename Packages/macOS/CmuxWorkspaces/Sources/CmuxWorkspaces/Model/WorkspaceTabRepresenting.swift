public import Foundation

/// The per-window workspace ("tab") seam `WorkspacesModel` and the workspace
/// coordinators operate through. The app target's `Workspace` god object is
/// the single conformer; the model stores conformers by reference and the
/// group/reorder logic reads exactly the identity, group-membership, and
/// pin state it needs — nothing else of the god object crosses the module
/// boundary.
///
/// Reference semantics are required: group membership (`groupId`) and pin
/// state are mutated in place on the live workspace object, exactly like the
/// legacy in-class code did.
@MainActor
public protocol WorkspaceTabRepresenting: AnyObject, Identifiable where ID == UUID {
    /// The workspace's stable identity.
    var id: UUID { get }
    /// The owning `WorkspaceGroup.id`, or `nil` when ungrouped.
    var groupId: UUID? { get set }
    /// Whether the workspace is pinned (pinned rows float above unpinned).
    var isPinned: Bool { get set }
    /// The workspace's current working directory (group creation inherits
    /// the anchor's / first child's cwd from this).
    var currentDirectory: String { get }
}
