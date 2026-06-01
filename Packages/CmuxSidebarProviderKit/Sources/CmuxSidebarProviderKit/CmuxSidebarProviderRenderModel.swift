import Foundation

public struct CmuxSidebarProviderRenderModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var snapshotSequence: UInt64
    public var sections: [CmuxSidebarProviderSection]
    public var presentation: CmuxSidebarProviderPresentation

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

public struct CmuxSidebarProviderRenderContext: Codable, Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }
}

public protocol CmuxContextualSidebarProvider: CmuxSidebarProvider {
    func render(snapshot: CmuxSidebarProviderSnapshot, context: CmuxSidebarProviderRenderContext) -> CmuxSidebarProviderRenderModel
}

public extension CmuxSidebarProvider {
    func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        CmuxSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    func render(
        snapshot: CmuxSidebarProviderSnapshot,
        context: CmuxSidebarProviderRenderContext
    ) -> CmuxSidebarProviderRenderModel {
        render(snapshot: snapshot)
    }
}
