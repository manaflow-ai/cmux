import Foundation

/// Provider that can both render sidebar state and handle host mutations.
public protocol CmuxMutableSidebarProvider: CmuxContextualSidebarProvider {
    /// Handles a mutation against the latest sidebar snapshot.
    func handle(
        _ mutation: CmuxSidebarProviderMutation,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> CmuxSidebarProviderCommandResult
}
