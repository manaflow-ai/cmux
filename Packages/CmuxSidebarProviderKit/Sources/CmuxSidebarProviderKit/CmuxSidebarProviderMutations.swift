import Foundation

public enum CmuxSidebarProviderPresentationRequest: Codable, Equatable, Sendable {
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    case openURL(String)
}

public struct CmuxSidebarProviderWorkspaceMove: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var sourceSectionId: String?
    public var targetSectionId: String
    public var targetIndex: Int

    public init(
        workspaceId: UUID,
        sourceSectionId: String?,
        targetSectionId: String,
        targetIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sourceSectionId = sourceSectionId
        self.targetSectionId = targetSectionId
        self.targetIndex = targetIndex
    }
}

public enum CmuxSidebarProviderMutation: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case createWorktree(projectRootPath: String)
    case moveWorkspace(CmuxSidebarProviderWorkspaceMove)
    case present(CmuxSidebarProviderPresentationRequest)
}

public struct CmuxSidebarProviderCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public protocol CmuxMutableSidebarProvider: CmuxContextualSidebarProvider {
    func handle(
        _ mutation: CmuxSidebarProviderMutation,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> CmuxSidebarProviderCommandResult
}
