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
