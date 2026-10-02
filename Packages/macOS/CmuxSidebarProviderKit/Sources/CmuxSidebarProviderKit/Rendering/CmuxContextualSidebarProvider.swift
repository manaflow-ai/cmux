import Foundation

/// Provider that renders with explicit render context.
public protocol CmuxContextualSidebarProvider: CmuxSidebarProvider {
    /// Builds a render model from a sidebar snapshot and render context.
    func render(snapshot: CmuxSidebarProviderSnapshot, context: CmuxSidebarProviderRenderContext) -> CmuxSidebarProviderRenderModel
}
