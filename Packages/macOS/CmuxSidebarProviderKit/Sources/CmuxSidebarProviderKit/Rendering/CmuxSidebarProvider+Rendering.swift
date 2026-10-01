import Foundation

public extension CmuxSidebarProvider {
    /// Builds the default empty render model for providers that do not implement rendering.
    func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        CmuxSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    /// Builds a render model using contextual rendering when available.
    func render(
        snapshot: CmuxSidebarProviderSnapshot,
        context: CmuxSidebarProviderRenderContext
    ) -> CmuxSidebarProviderRenderModel {
        render(snapshot: snapshot)
    }
}
