import Foundation

extension SidebarLayoutDocument {
    /// The ops that move a pre-rail layout to the current defaults.
    public nonisolated var railMigrationOps: [SidebarLayoutOp] { [] }

    /// This layout with `railMigrationOps` applied.
    public nonisolated var migratedToRail: SidebarLayoutDocument { self }
}
