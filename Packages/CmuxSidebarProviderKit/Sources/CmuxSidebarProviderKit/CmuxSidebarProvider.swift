import Foundation

/// In-process sidebar provider used by CMUX-owned sidebar presentations.
public protocol CmuxSidebarProvider: Sendable {
    /// Stable metadata describing the provider in selection UI.
    var descriptor: CmuxSidebarProviderDescriptor { get }

    /// Builds a render model from the latest sidebar snapshot.
    func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel
}
