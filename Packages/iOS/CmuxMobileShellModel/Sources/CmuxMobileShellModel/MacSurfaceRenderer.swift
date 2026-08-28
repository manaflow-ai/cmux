public import CMUXMobileCore

/// The native iOS renderer chosen for one Mac surface snapshot.
///
/// The decision is pure so the kind → renderer dispatch stays testable away
/// from SwiftUI: capability gating and payload presence both live here, and
/// the view layer switches on the result without re-deriving policy.
public enum MacSurfaceRenderer: Equatable, Sendable {
    /// Native checklist and status lane backed by `todo.v1` mutations.
    case todo(MobileTodoSnapshot)
    /// Native panel-scoped file preview backed by `panel.artifact.v1`.
    case filePreview(path: String)
    /// Native panel-scoped markdown rendering backed by `panel.artifact.v1`.
    case markdown(path: String)
    /// Kind-specific card for surfaces that stay rendered on the Mac.
    case fallbackCard

    /// Chooses the renderer for a surface given the owning Mac's capabilities.
    ///
    /// - Parameters:
    ///   - surface: The synced surface snapshot.
    ///   - supportsTodo: Whether the owning Mac advertises `todo.v1`. Unused
    ///     for rendering: the todo snapshot is synced data that stays valid
    ///     while the connection recovers, so the checklist keeps rendering
    ///     (like the terminal's last frame) and the capability only gates
    ///     mutations at the view layer.
    ///   - supportsPanelArtifacts: Whether the connected Mac advertises
    ///     `panel.artifact.v1` panel file reads.
    /// - Returns: The renderer to mount; `.fallbackCard` whenever a required
    ///   capability or payload is missing.
    public static func resolve(
        surface: MobileSurfacePreview,
        supportsTodo: Bool,
        supportsPanelArtifacts: Bool
    ) -> MacSurfaceRenderer {
        switch surface.kind {
        case .todo:
            guard let todo = surface.todo else { return .fallbackCard }
            return .todo(todo)
        case .filePreview:
            guard supportsPanelArtifacts, let path = normalizedFilePath(surface) else {
                return .fallbackCard
            }
            return .filePreview(path: path)
        case .markdown:
            guard supportsPanelArtifacts, let path = normalizedFilePath(surface) else {
                return .fallbackCard
            }
            return .markdown(path: path)
        case .terminal, .browser, .rightSidebarTool, .customSidebar, .agentSession,
             .project, .extensionBrowser, .cloudVMLoading, .other:
            return .fallbackCard
        }
    }

    private static func normalizedFilePath(_ surface: MobileSurfacePreview) -> String? {
        guard let path = surface.filePath, !path.isEmpty else { return nil }
        return path
    }
}
