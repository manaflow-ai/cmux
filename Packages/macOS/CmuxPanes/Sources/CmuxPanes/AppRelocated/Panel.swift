import Foundation
import CmuxCore
import CmuxPanes
import CmuxWorkspaces

extension PanelType {
    /// The workspace ``SurfaceKind`` a panel of this type registers as on its
    /// bonsplit tab and in session snapshots.
    ///
    /// Faithful lift of the private `Workspace.surfaceKind(for:)` switch onto the
    /// owning type. The mapping is deliberately NOT identity over `rawValue`:
    /// `PanelType.filePreview.rawValue` is `"filepreview"` while the persisted
    /// surface kind is `SurfaceKind.filePreview` (`"filePreview"`), so the
    /// explicit case mapping is preserved rather than collapsed.
    ///
    /// This extension stays app-target because `SurfaceKind` lives in
    /// `CmuxWorkspaces`, which depends on `CmuxPanes` (where `PanelType` now
    /// lives); putting it in `CmuxPanes` would create a dependency cycle.
    public var surfaceKind: SurfaceKind {
        switch self {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .extensionBrowser
        }
    }
}

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionFlashReason`; this
/// typealias keeps the unqualified app-target call sites byte-identical.
public typealias WorkspaceAttentionFlashReason = CmuxCore.WorkspaceAttentionFlashReason

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionPersistentState`;
/// this typealias keeps the unqualified app-target call sites byte-identical.
typealias WorkspaceAttentionPersistentState = CmuxCore.WorkspaceAttentionPersistentState

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionFlashDecision`;
/// this typealias keeps the unqualified app-target call sites byte-identical.
typealias WorkspaceAttentionFlashDecision = CmuxCore.WorkspaceAttentionFlashDecision
