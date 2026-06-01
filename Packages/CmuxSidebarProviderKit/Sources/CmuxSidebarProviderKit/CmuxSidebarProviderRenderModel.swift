import Foundation

/// Complete render model emitted by an in-process sidebar provider.
public struct CmuxSidebarProviderRenderModel: Codable, Equatable, Sendable {
    /// Provider id that produced this model.
    public var providerId: String
    /// Snapshot sequence this model was rendered from.
    public var snapshotSequence: UInt64
    /// Sidebar sections to display.
    public var sections: [CmuxSidebarProviderSection]
    /// Layout CMUX should use for the sections.
    public var presentation: CmuxSidebarProviderPresentation

    /// Creates a provider render model.
    public init(
        providerId: String,
        snapshotSequence: UInt64,
        sections: [CmuxSidebarProviderSection],
        presentation: CmuxSidebarProviderPresentation = .tree
    ) {
        self.providerId = providerId
        self.snapshotSequence = snapshotSequence
        self.sections = sections
        self.presentation = presentation
    }
}

/// Render-time context for values that should not be persisted in snapshots.
public struct CmuxSidebarProviderRenderContext: Codable, Equatable, Sendable {
    /// Current render time used for relative-date text.
    public var now: Date

    /// Creates a render context.
    public init(now: Date) {
        self.now = now
    }
}

/// Provider that renders with explicit render context.
public protocol CmuxContextualSidebarProvider: CmuxSidebarProvider {
    /// Builds a render model from a sidebar snapshot and render context.
    func render(snapshot: CmuxSidebarProviderSnapshot, context: CmuxSidebarProviderRenderContext) -> CmuxSidebarProviderRenderModel
}

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
